@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Room Host drain retains a real PostgreSQL activation", .serialized, .timeLimit(.minutes(2)))
struct V2RoomHostPostgresDrainTests {
    @Test("drain timeout cannot release a lease before a fenced transaction commits",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_DRAIN_DATABASE_IS_DISPOSABLE"] == "1"))
    func fencedTransactionOutlivesDrainDeadline() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_DRAIN_DATABASE_URL"])
        // The shared schema helper also requires this switch. A Host-specific
        // opt-in must fail visibly instead of returning before any SQL runs.
        try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1")
        try await withUserEventDatabase(databaseURL: url) { database, sql, schema in
            let roomUUID = UUID()
            let room = RoomID(uuid: roomUUID)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: roomUUID), 'owner-a', 'standard')
                """).run()

            let leases = PostgresV2RoomActivationStore(database: database, schema: schema)
            let firstIdentity = V2ActorHostIdentity(hostID: try .init("draining-host"),
                incarnationID: UUID())
            let nextIdentity = V2ActorHostIdentity(hostID: try .init("successor-host"),
                incarnationID: UUID())
            let configuration = try V2RoomRuntimeConfiguration()
            let budget = V2RoomCommandBudget(configuration: configuration)
            let transactionGate = DrainPhaseGate()
            let closeGate = DrainPhaseGate()
            defer {
                Task {
                    await transactionGate.open()
                    await closeGate.open()
                }
            }
            let host = V2RoomActivationHost<DrainCommand, Int>(
                identity: firstIdentity, leaseStore: leases, configuration: configuration,
                budget: budget, classify: { _ in .barrier },
                factory: .init { token in
                    .init(restore: { deadline in
                        try await V2RoomSQLDeadline.withDeadline(deadline) {
                            try await v2WithRoomScopedTransaction(database: database) { transaction in
                                let transactionSQL = try #require(transaction as? any SQLDatabase)
                                try await v2RequireRoomActivation(token: token,
                                    sql: transactionSQL, schema: schema)
                            }
                        }
                    }, execute: { turn in
                        do {
                            let deadline = try #require(turn.items.first?.deadline)
                            let value = try await V2RoomSQLDeadline.withDeadline(deadline) {
                                try await v2WithRoomScopedTransaction(database: database) { transaction in
                                    let transactionSQL = try #require(transaction as? any SQLDatabase)
                                    try await v2RequireRoomActivation(token: token,
                                        sql: transactionSQL, schema: schema)
                                    await transactionGate.enterAndWait()
                                    try await transactionSQL.raw("""
                                        UPDATE \(unsafeRaw: schema).rooms
                                        SET room_sequence = room_sequence + 1
                                        WHERE room_id = \(bind: roomUUID)
                                        """).run()
                                    return 1
                                }
                            }
                            return .committed([value])
                        } catch {
                            return .rolledBack(.unavailable)
                        }
                    }, invalidateReservation: { _ in },
                    close: { await closeGate.enterAndWait() })
                }
            )
            await host.start()
            guard case .ready(let firstToken) = try await host.activate(roomID: room,
                owner: owner, deadline: .now + .seconds(5)) else {
                Issue.record("room did not become ready"); return
            }

            let call = Task {
                try await host.invoke(token: firstToken,
                    request: DrainCommand(),
                    deadline: .now + .seconds(5))
            }
            try await transactionGate.waitForEntry()
            let timedOutDrain = await host.drain(deadline: .now + .milliseconds(60))
            #expect(!timedOutDrain.completed)
            #expect(timedOutDrain.remainingRooms == 1)
            #expect(await host.readyTokens().isEmpty)
            #expect(await closeGate.entryCount == 0)
            #expect(try await sql.raw("""
                SELECT COUNT(*)::bigint AS value
                FROM \(unsafeRaw: schema).room_activation_leases
                WHERE room_id = \(bind: roomUUID) AND activation_epoch = \(bind: firstToken.activationEpoch.rawValue)
                  AND host_incarnation_id = \(bind: firstIdentity.incarnationID)
                  AND expires_at > clock_timestamp()
                """).first(decoding: DrainCountRow.self)?.value == 1)

            await transactionGate.open()
            #expect(try await call.value == 1)
            try await closeGate.waitForEntry()
            let contender = try await leases.acquire(roomID: room,
                owner: owner, host: nextIdentity, duration: .init(30_000))
            await closeGate.open()
            guard case .occupied(let occupied) = contender else {
                Issue.record("successor acquired while old executor was closing"); return
            }
            #expect(occupied.token == firstToken)
            #expect(try await sql.raw("""
                SELECT room_sequence AS value FROM \(unsafeRaw: schema).rooms
                WHERE room_id = \(bind: roomUUID)
                """).first(decoding: DrainCountRow.self)?.value == 1)
            #expect((await host.drain(deadline: .now + .seconds(5))).completed)
            #expect(try await leases.locate(roomID: room, owner: owner) == nil)
            guard case .acquired(let successor) = try await leases.acquire(roomID: room,
                owner: owner, host: nextIdentity, duration: .init(30_000)) else {
                Issue.record("successor did not acquire released room"); return
            }
            #expect(successor.token.activationEpoch.rawValue == firstToken.activationEpoch.rawValue + 1)
            #expect(try await leases.release(token: firstToken) == false)
            #expect(try await leases.release(token: successor.token))
            #expect(await budget.snapshot().commandCount == 0)
        }
    }
}

private struct DrainCommand: Codable, Sendable {}

private struct DrainCountRow: Decodable {
    let value: Int64
}

private actor DrainPhaseGate {
    private var entered = false
    private var opened = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func enterAndWait() async {
        entryCount += 1
        entered = true
        if opened { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitForEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            guard ContinuousClock.now < deadline else { throw DrainTestFailure.phaseTimeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        opened = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll()
    }
}

private enum DrainTestFailure: Error { case phaseTimeout }
