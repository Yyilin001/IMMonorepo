import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Room Host concrete restore and retirement against PostgreSQL", .serialized, .timeLimit(.minutes(3)))
struct V2RoomHostPostgresLifecycleTests {
    @Test("lease changes during concrete restore never publish a half actor and recovery gets a new epoch",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE"] == "1"))
    func lostLeaseDuringRestore() async throws {
        try await withG2HostDatabase { database, sql, fixture in
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let barrier = G2PhaseBarrier(target: roomID)
            let config = try g2RuntimeConfiguration()
            let hosted = try g2Host(database: database, fixture: fixture, leaseStore: leases,
                configuration: config, restoreBarrier: barrier)
            let host = hosted.host
            await host.start()
            do {
                let first = Task {
                    try await host.activate(roomID: roomID, owner: owner, deadline: .now + .seconds(5))
                }
                let old = try await barrier.waitForToken()
                #expect(await host.readyTokens().isEmpty)
                #expect(await host.snapshot().pendingRooms == 1)

                // This is the real DB authority changing after acquire but
                // before V2RoomServerActivation.restore validates its token.
                #expect(try await leases.release(token: old))
                let other = V2ActorHostIdentity(hostID: try .init("g2-takeover"), incarnationID: UUID())
                guard case .acquired(let successor) = try await leases.acquire(roomID: roomID,
                    owner: owner, host: other, duration: .init(30_000)) else {
                    throw G2TestFailure.successorUnavailable
                }
                await barrier.open()
                await g2ExpectFailure(.notAccepted(.unavailable), first)
                try await g2WaitUntil {
                    let snapshot = await host.snapshot()
                    return snapshot.pendingRooms == 0 && snapshot.retiringRooms == 0
                }
                #expect(await host.readyTokens().isEmpty)
                #expect(try await leases.locate(roomID: roomID, owner: owner)?.token == successor.token)
                #expect(try await leases.release(token: successor.token))

                guard case .ready(let recovered) = try await host.activate(roomID: roomID,
                    owner: owner, deadline: .now + .seconds(5)) else {
                    throw G2TestFailure.recoveryNotReady
                }
                #expect(recovered.activationEpoch.rawValue == successor.token.activationEpoch.rawValue + 1)
                try await g2AssertConcreteRecovery(host: host, token: recovered, room: roomID)
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
                #expect(await hosted.budget.snapshot().commandCount == 0)
                #expect(try await sql.raw("""
                    SELECT COUNT(*)::bigint AS value FROM im_v2.room_activation_leases
                    WHERE room_id = \(bind: roomUUID) AND expires_at IS NOT NULL
                    """).first(decoding: G2CountRow.self)?.value == 0)
            } catch {
                await barrier.open()
                _ = await host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("one cancelled waiter cannot cancel a shared concrete restore",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE"] == "1"))
    func cancelledWaiterSharesRestore() async throws {
        try await withG2HostDatabase { database, _, fixture in
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let barrier = G2PhaseBarrier(target: roomID)
            let hosted = try g2Host(database: database, fixture: fixture, leaseStore: leases,
                configuration: g2RuntimeConfiguration(), restoreBarrier: barrier)
            let host = hosted.host
            await host.start()
            do {
                let first = Task {
                    try await host.activate(roomID: roomID, owner: owner, deadline: .now + .seconds(5))
                }
                let tokenBeforeReady = try await barrier.waitForToken()
                let second = Task {
                    try await host.activate(roomID: roomID, owner: owner, deadline: .now + .seconds(5))
                }
                try await g2WaitUntil { await host.snapshot().activationWaiters == 2 }
                first.cancel()
                await g2ExpectFailure(.notAccepted(.cancelled), first)
                #expect(await host.snapshot().activationWaiters == 1)
                #expect(await host.readyTokens().isEmpty)
                await barrier.open()
                guard case .ready(let token) = try await second.value else {
                    throw G2TestFailure.recoveryNotReady
                }
                #expect(token == tokenBeforeReady)
                #expect(token.activationEpoch.rawValue == 1)
                try await g2AssertConcreteRecovery(host: host, token: token, room: roomID)
                #expect(await host.snapshot().activationWaiters == 0)
                #expect(await hosted.budget.snapshot().commandCount == 0)
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
                #expect(try await leases.locate(roomID: roomID, owner: owner) == nil)
            } catch {
                await barrier.open()
                _ = await host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("stalled restore and idle retirement preserve healthy service and exact-token handoff",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE"] == "1"))
    func saturatedRestoreAndIdleHandoff() async throws {
        try await withG2HostDatabase { database, sql, fixture in
            let hotUUID = UUID(), excessUUID = UUID()
            let hotRoom = RoomID(uuid: hotUUID), excessRoom = RoomID(uuid: excessUUID)
            try await sql.raw("""
                INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id)
                VALUES (\(bind: hotUUID), 'room-a', 'standard'),
                       (\(bind: excessUUID), 'room-a', 'standard')
                """).run()
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let restoreGate = G2PhaseBarrier(target: hotRoom)
            let closeGate = G2PhaseBarrier(target: hotRoom)
            let hosted = try g2Host(database: database, fixture: fixture, leaseStore: leases,
                configuration: g2RuntimeConfiguration(idleMilliseconds: 800),
                restoreBarrier: restoreGate, closeBarrier: closeGate)
            let host = hosted.host
            await host.start()
            do {
                guard case .ready(let healthy) = try await host.activate(roomID: roomID,
                    owner: owner, deadline: .now + .seconds(5)) else {
                    throw G2TestFailure.recoveryNotReady
                }
                let hot = Task {
                    try await host.activate(roomID: hotRoom, owner: owner,
                        deadline: .now + .seconds(5))
                }
                let hotBeforeReady = try await restoreGate.waitForToken()
                #expect(await host.snapshot().restoringRooms == 1)
                #expect(await host.snapshot().pendingRooms == 1)
                #expect(await host.readyTokens() == [healthy])
                await g2ExpectFailure(.notAccepted(.overloaded), Task {
                    try await host.activate(roomID: excessRoom, owner: owner,
                        deadline: .now + .seconds(1))
                })
                #expect(try await leases.locate(roomID: excessRoom, owner: owner) == nil)
                try await g2AssertConcreteRecovery(host: host, token: healthy, room: roomID)
                #expect(await hosted.budget.snapshot().commandCount == 0)

                await restoreGate.open()
                guard case .ready(let firstHot) = try await hot.value else {
                    throw G2TestFailure.recoveryNotReady
                }
                #expect(firstHot == hotBeforeReady)
                #expect(try await closeGate.waitForToken() == firstHot)
                await g2ExpectFailure(.notAccepted(.retired), Task {
                    try await host.activate(roomID: hotRoom, owner: owner,
                        deadline: .now + .seconds(1))
                })
                #expect(try await leases.locate(roomID: hotRoom, owner: owner)?.token == firstHot)
                await closeGate.open()
                try await g2WaitUntil {
                    try await leases.locate(roomID: hotRoom, owner: owner) == nil
                }
                guard case .ready(let nextHot) = try await host.activate(roomID: hotRoom,
                    owner: owner, deadline: .now + .seconds(5)) else {
                    throw G2TestFailure.recoveryNotReady
                }
                #expect(nextHot.activationEpoch.rawValue == firstHot.activationEpoch.rawValue + 1)
                #expect(try await leases.release(token: firstHot) == false)
                #expect(try await leases.locate(roomID: hotRoom, owner: owner)?.token == nextHot)
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
                #expect(await hosted.budget.snapshot().commandCount == 0)
            } catch {
                await restoreGate.open()
                await closeGate.open()
                _ = await host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }
}

private struct G2HostedRoom {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
}

private func g2RuntimeConfiguration(idleMilliseconds: Int64 = 300_000) throws -> V2RoomRuntimeConfiguration {
    try .init(maximumActiveRooms: 2, maximumConcurrentRestores: 1,
        maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 1,
        maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 1,
        maximumConcurrentReservations: 2, idleTimeoutMilliseconds: idleMilliseconds)
}

private func g2Host(database: any Database, fixture: PostgresV2RoomWriteStoreIntegrationTests,
    leaseStore: PostgresV2RoomActivationStore, configuration: V2RoomRuntimeConfiguration,
    restoreBarrier: G2PhaseBarrier, closeBarrier: G2PhaseBarrier? = nil) throws -> G2HostedRoom {
    let writes = PostgresV2RoomWriteStore(database: database)
    let batcher = V2SendMessageAdmissionBatcher(store: writes,
        configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(2)),
        actorGrantedStore: writes)
    let ownerResources = try V2RoomServerOwnerResources(database: database, writes: writes,
        sendBatcher: batcher,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        receiptShadowForwarder: G2ShadowForwarder(),
        capacityProfile: fixture.forwardImportTestProfile(),
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init())
    let concrete = try V2RoomServerActivationFactory(owners: ["room-a": ownerResources],
        safetyActorUserID: senderID).runtimeFactory()
    let wrapped = V2RoomActivationFactory<V2RoomRequest, V2RoomResponse> { token in
        let actual = concrete.make(token)
        return .init(restore: { deadline in
            await restoreBarrier.enterIfTarget(token)
            try await actual.restore(deadline)
        }, execute: actual.execute, invalidateReservation: actual.invalidateReservation,
        close: {
            if let closeBarrier { await closeBarrier.enterIfTarget(token) }
            await actual.close()
        })
    }
    let budget = V2RoomCommandBudget(configuration: configuration)
    let identity = V2ActorHostIdentity(hostID: try .init("g2-concrete-host"), incarnationID: UUID())
    return .init(host: .init(identity: identity, leaseStore: leaseStore,
        configuration: configuration, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: wrapped), budget: budget)
}

private func g2AssertConcreteRecovery(host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
    token: V2RoomActivationToken, room: RoomID) async throws {
    let request = V2RoomRequest.recovery(.init(roomID: room, actorUserID: senderID, kind: .state))
    let response = try await host.invoke(token: token,
        encodedRequest: JSONEncoder().encode(request), deadline: .now + .seconds(5))
    guard case .recovery(.state(.state(let state))) = response,
          state.roomID == room else { throw G2TestFailure.recoveryQueryFailed }
}

private func g2ExpectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private func g2WaitUntil(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw G2TestFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor G2PhaseBarrier {
    private let target: RoomID
    private var token: V2RoomActivationToken?
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: RoomID) { self.target = target }

    func enterIfTarget(_ value: V2RoomActivationToken) async {
        guard value.roomID == target, !opened else { return }
        token = value
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForToken() async throws -> V2RoomActivationToken {
        let deadline = ContinuousClock.now + .seconds(5)
        while token == nil {
            guard ContinuousClock.now < deadline else { throw G2TestFailure.phaseTimeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        return token!
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct G2ShadowForwarder: V2UserShardProjectionShadowing {
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private struct G2CountRow: Decodable { let value: Int64 }

private enum G2TestFailure: Error {
    case disposableDatabaseRequired
    case successorUnavailable
    case recoveryNotReady
    case recoveryQueryFailed
    case phaseTimeout
}

private func withG2HostDatabase(_ operation: (any Database, any SQLDatabase,
    PostgresV2RoomWriteStoreIntegrationTests) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_G2_DATABASE_IS_DISPOSABLE"] == "1" else {
        throw G2TestFailure.disposableDatabaseRequired
    }
    let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_HOST_G2_DATABASE_URL"])
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: G2BoolRow.self)?.value == false else {
            throw TestConfigurationError.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(on: sql)
        try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
        try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
        try await operation(database, sql, fixture)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        installed = false
        try await resources.shutdown()
    } catch {
        if installed, let sql = resources.database(.psql) as? any SQLDatabase {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        }
        try? await resources.shutdown()
        throw error
    }
}

private struct G2BoolRow: Decodable { let value: Bool }
