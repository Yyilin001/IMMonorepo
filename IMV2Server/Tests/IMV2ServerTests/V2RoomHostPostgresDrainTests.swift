@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Native Room Host drain retains physical PostgreSQL work", .serialized, .timeLimit(.minutes(2)))
struct V2RoomHostPostgresDrainTests {
    @Test("drain timeout cannot authorize a successor before SQL and executor close settle",
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

            let firstIdentity = V2ActorHostIdentity(hostID: try .init("draining-host"),
                incarnationID: UUID())
            let nextIdentity = V2ActorHostIdentity(hostID: firstIdentity.hostID,
                incarnationID: UUID())
            try await withNativePlacementTestControl(host: firstIdentity, shardID: owner.shardID) { control in
            let placement = try await control.register(firstIdentity, shard: owner.shardID)
            let configuration = try V2RoomRuntimeConfiguration()
            let budget = V2RoomCommandBudget(configuration: configuration)
            let transactionGate = DrainPhaseGate()
            let closeGate = DrainPhaseGate()
            let factory = V2RoomActivationFactory<DrainCommand, Int> { token in
                    .init(restore: { deadline in
                        try await deadline.validate()
                        try await V2RoomSQLDeadline.withDeadline(deadline.deadline) {
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
            let host = V2RoomActivationHost<DrainCommand, Int>(identity: firstIdentity,
                placement: placement, configuration: configuration, budget: budget,
                classify: { _ in .barrier }, factory: factory)
            var activeCall: Task<Int, any Error>?
            var successorHost: V2RoomActivationHost<DrainCommand, Int>?
            do {
            await host.start()
            guard case .ready(let firstToken) = try await host.activate(roomID: room,
                owner: owner, deadline: .now + .seconds(5)) else {
                throw DrainTestFailure.phaseTimeout
            }

            let call = Task {
                try await host.invoke(token: firstToken,
                    request: DrainCommand(),
                    deadline: .now + .seconds(5))
            }
            activeCall = call
            try await transactionGate.waitForEntry()
            let timedOutDrain = await host.drain(deadline: .now + .milliseconds(60))
            #expect(!timedOutDrain.completed)
            #expect(timedOutDrain.remainingRooms == 1)
            #expect(await host.readyTokens().isEmpty)
            #expect(await closeGate.entryCount == 0)
            #expect(timedOutDrain.proof == nil)
            await #expect(throws: V2ActorPlacementError.staleOwner) {
                _ = try await control.register(nextIdentity, shard: owner.shardID)
            }

            await transactionGate.open()
            #expect(try await call.value == 1)
            try await closeGate.waitForEntry()
            await #expect(throws: V2ActorPlacementError.staleOwner) {
                _ = try await control.register(nextIdentity, shard: owner.shardID)
            }
            await closeGate.open()
            #expect(try await sql.raw("""
                SELECT room_sequence AS value FROM \(unsafeRaw: schema).rooms
                WHERE room_id = \(bind: roomUUID)
                """).first(decoding: DrainCountRow.self)?.value == 1)
            let drained = await host.stop(deadline: .now + .seconds(5))
            try #require(drained.completed)
            try await placement.retireAfterDrain(try #require(drained.proof), shards: [owner.shardID])
            let successorPlacement = try await control.register(nextIdentity, shard: owner.shardID)
            let next = V2RoomActivationHost<DrainCommand, Int>(identity: nextIdentity,
                placement: successorPlacement, configuration: configuration,
                budget: .init(configuration: configuration), classify: { _ in .barrier }, factory: factory)
            successorHost = next
            await next.start()
            guard case .ready(let successor) = try await next.activate(roomID: room, owner: owner,
                deadline: .now + .seconds(5)) else { throw DrainTestFailure.phaseTimeout }
            #expect(successor.host == nextIdentity)
            #expect(successor.activationEpoch.rawValue > firstToken.activationEpoch.rawValue)
            await #expect(throws: V2RoomCallFailure.self) {
                _ = try await host.invoke(token: firstToken, request: DrainCommand(), deadline: .now + .seconds(5))
            }
            let nextDrained = await next.stop(deadline: .now + .seconds(5))
            try #require(nextDrained.completed)
            try await successorPlacement.retireAfterDrain(try #require(nextDrained.proof), shards: [owner.shardID])
            #expect(await budget.snapshot().commandCount == 0)
            } catch {
                await transactionGate.open()
                await closeGate.open()
                _ = await activeCall?.result
                _ = await host.stop(deadline: .now + .seconds(10))
                _ = await successorHost?.stop(deadline: .now + .seconds(10))
                throw error
            }
            }
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
