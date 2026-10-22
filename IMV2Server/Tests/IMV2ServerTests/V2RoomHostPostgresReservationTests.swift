@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorCluster
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Room Host pair reservations and recovery reads against PostgreSQL", .serialized,
       .timeLimit(.minutes(3)))
struct V2RoomHostPostgresReservationTests {
    @Test("a granted B recovery flushes while A waits behind an A-to-B pair reservation",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_IS_DISPOSABLE"] == "1"))
    func grantedReadDoesNotWaitForUnadmittedRoom() async throws {
        try await withPairDatabase { database, sql, seed, policies in
            let identity = V2ActorHostIdentity(hostID: try .init("pair-pg-host"), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: "room-a") { control in
                let placement = try await control.register(identity, shard: "room-a")
                let hosted = try makePairHost(database: database, profile: seed.profile, identity: identity, placement: placement, policies: policies)
                let host = hosted.host
                let trace = PairReservationTrace()
                let coordinator = pairCoordinator(host: host, configuration: hosted.configuration,
                    tokens: hosted.tokens, trace: trace)
                let executor = try pairExecutor(database: database, profile: seed.profile,
                    admission: hosted.admission, policies: policies)
                let forward = pairWire(sourceRoom: seed.a, targetRoom: seed.b,
                    sourceMessage: seed.aSource.messageID)
                let rowLock = PairPhaseGate()
                await host.start()
                try await activatePair(host: host, seed: seed, into: hosted.tokens)
                let tokenA = try #require(await hosted.tokens.get(seed.a))
                let tokenB = try #require(await hosted.tokens.get(seed.b))
                let locker = Task {
                    try await database.transaction { transaction in
                        let txSQL = try #require(transaction as? any SQLDatabase)
                        try await txSQL.raw("""
                            SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: seed.b.uuidValue!)
                            FOR NO KEY UPDATE
                            """).run()
                        await rowLock.hold()
                    }
                }
                do {
                    try await rowLock.waitUntilHeld()
                    let bQuery = Task {
                        try await host.invoke(token: tokenB,
                            request: try recoveryBytes(seed.b), deadline: .now + .seconds(8))
                    }
                    try await pairWaitUntil {
                        await hosted.admission.snapshot().interactiveRead.inFlight == 1
                    }
                    let pairDeadline = ContinuousClock.now + .seconds(8)
                    let pair = Task { () throws -> V2ActorForwardMessageResultWire in
                        try await coordinator.withReservations(source: seed.a, target: seed.b,
                            deadline: pairDeadline) { grants in
                            await pairExecution(executor: executor, wire: forward, grants: grants,
                                deadline: pairDeadline)
                        }
                    }
                    try await trace.waitForGranted(seed.a)
                    try await trace.waitForAttempt(seed.b)
                    let aQuery = Task {
                        try await host.invoke(token: tokenA,
                            request: try recoveryBytes(seed.a), deadline: .now + .seconds(8))
                    }
                    try await pairWaitUntil { await hosted.budget.snapshot().commandCount >= 4 }
                    #expect(await hosted.admission.snapshot().interactiveRead.inFlight == 1)
                    #expect(await coordinator.activePairCount() == 1)
                    await rowLock.open()
                    try await locker.value

                    let beforePair = try recoveryHead(await bQuery.value, room: seed.b)
                    #expect(beforePair == 1)
                    let result = try await pair.value
                    #expect(result.errorCode == nil)
                    #expect(result.messageID != nil)
                    let afterPair = try recoveryHead(await aQuery.value, room: seed.a)
                    #expect(afterPair == 1)
                    #expect(try await pairRoomHead(sql: sql, room: seed.b) == 2)
                    #expect(try await pairForwardCount(sql: sql, operation: forward.operationID.uuidValue!) == 1)
                    #expect(await hosted.budget.snapshot().commandCount == 0)
                    let reads = await hosted.admission.snapshot().interactiveRead
                    #expect(reads.admittedRequests == 2 && reads.inFlight == 0)
                    let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
                    try await placement.retireAfterDrain(proof, shards: ["room-a"])
                } catch {
                    await rowLock.open()
                    _ = try? await locker.value
                    let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
                    try await placement.retireAfterDrain(proof, shards: ["room-a"])
                    throw error
                }
            }
        }
    }

    @Test("opposite pairs acquire A then B; cancelled waiter releases capacity and post-SQL unknown retires both",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_IS_DISPOSABLE"] == "1"))
    func opposingPairCancellationAndUnknown() async throws {
        try await withPairDatabase { database, sql, seed, policies in
            let identity = V2ActorHostIdentity(hostID: try .init("pair-pg-host"), incarnationID: UUID())
            try await withNativePlacementTestControl(host: identity, shardID: "room-a") { control in
                let placement = try await control.register(identity, shard: "room-a")
                let hosted = try makePairHost(database: database, profile: seed.profile, identity: identity, placement: placement, policies: policies)
                let host = hosted.host
                let trace = PairReservationTrace()
                let coordinator = pairCoordinator(host: host, configuration: hosted.configuration,
                    tokens: hosted.tokens, trace: trace)
                let executor = try pairExecutor(database: database, profile: seed.profile,
                    admission: hosted.admission, policies: policies)
                let firstWire = pairWire(sourceRoom: seed.a, targetRoom: seed.b,
                    sourceMessage: seed.aSource.messageID)
                let unknownWire = pairWire(sourceRoom: seed.b, targetRoom: seed.a,
                    sourceMessage: seed.bSource.messageID)
                let firstSQLGate = PairPhaseGate()
                let committedUnknown = PairCommittedOutcome()
                await host.start()
                try await activatePair(host: host, seed: seed, into: hosted.tokens)
                let oldA = try #require(await hosted.tokens.get(seed.a))
                let oldB = try #require(await hosted.tokens.get(seed.b))
                do {
                    let firstDeadline = ContinuousClock.now + .seconds(8)
                    let first = Task { () throws -> V2ActorForwardMessageResultWire in
                        try await coordinator.withReservations(source: seed.a, target: seed.b,
                            deadline: firstDeadline) { grants in
                            await firstSQLGate.hold()
                            return await pairExecution(executor: executor, wire: firstWire, grants: grants,
                                deadline: firstDeadline)
                        }
                    }
                    try await firstSQLGate.waitUntilHeld()
                    let firstID = try #require(await trace.requestIDs().first)
                    #expect(await trace.attempted(for: firstID) == [seed.a, seed.b])
                    #expect(await trace.acquired(for: firstID) == [seed.a, seed.b])

                    let cancelledDeadline = ContinuousClock.now + .seconds(8)
                    let cancelled = Task { () throws -> V2ActorForwardMessageResultWire in
                        try await coordinator.withReservations(source: seed.b, target: seed.a,
                            deadline: cancelledDeadline) { _ in
                            Issue.record("cancelled pair entered SQL")
                            return .rolledBack(.invalidRequest)
                        }
                    }
                    try await trace.waitForRequests(2)
                    let cancelledID = try #require(await trace.requestIDs().last)
                    #expect(await trace.attempted(for: cancelledID) == [seed.a])
                    #expect(await trace.acquired(for: cancelledID).isEmpty)
                    cancelled.cancel()
                    await pairExpectFailure(.notAccepted(.cancelled), cancelled)
                    try await pairWaitUntil { await hosted.budget.snapshot().reservationCount == 2 }

                    let unknownDeadline = ContinuousClock.now + .seconds(8)
                    let unknown = Task { () throws -> V2ActorForwardMessageResultWire in
                        try await coordinator.withReservations(source: seed.b, target: seed.a,
                            deadline: unknownDeadline) { grants in
                            let completion = await pairExecution(executor: executor,
                                wire: unknownWire, grants: grants, deadline: unknownDeadline)
                            if case .committed(let value) = completion {
                                await committedUnknown.record(value)
                                // The PostgreSQL COMMIT succeeded; only the
                                // coordinator's completion observation is lost.
                                return .outcomeUnknown
                            }
                            return completion
                        }
                    }
                    try await trace.waitForRequests(3)
                    let unknownID = try #require(await trace.requestIDs().last)
                    #expect(await trace.attempted(for: unknownID) == [seed.a])
                    #expect(await trace.acquired(for: unknownID).isEmpty)
                    #expect(await coordinator.activePairCount() == 2)

                    await firstSQLGate.open()
                    let firstResult = try await first.value
                    #expect(firstResult.errorCode == nil && firstResult.messageID != nil)
                    await pairExpectFailure(.outcomeUnknown, unknown)
                    let durableUnknown = try #require(await committedUnknown.value())
                    #expect(durableUnknown.errorCode == nil && durableUnknown.messageID != nil)
                    #expect(await trace.attempted(for: unknownID) == [seed.a, seed.b])
                    #expect(await trace.acquired(for: unknownID) == [seed.a, seed.b])
                    #expect(try await pairForwardCount(sql: sql,
                        operation: firstWire.operationID.uuidValue!) == 1)
                    #expect(try await pairForwardCount(sql: sql,
                        operation: unknownWire.operationID.uuidValue!) == 1)
                    try await pairWaitUntil {
                        let snapshot = await host.snapshot()
                        let budget = await hosted.budget.snapshot()
                        return snapshot.activeRooms == 0 && snapshot.retiringRooms == 0 &&
                            budget.commandCount == 0
                    }
                    #expect(await host.readyTokens().isEmpty)
                    #expect(!(await host.isReady(token: oldA)))
                    #expect(!(await host.isReady(token: oldB)))

                    try await activatePair(host: host, seed: seed, into: hosted.tokens)
                    let freshA = try #require(await hosted.tokens.get(seed.a))
                    let freshB = try #require(await hosted.tokens.get(seed.b))
                    #expect(freshA.activationEpoch.rawValue > oldA.activationEpoch.rawValue)
                    #expect(freshB.activationEpoch.rawValue > oldB.activationEpoch.rawValue)
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await host.invoke(token: oldA, request: recoveryBytes(seed.a), deadline: .now + .seconds(5))
                    }
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await host.invoke(token: oldB, request: recoveryBytes(seed.b), deadline: .now + .seconds(5))
                    }
                    let replayDeadline = ContinuousClock.now + .seconds(8)
                    let replay = try await coordinator.withReservations(source: seed.b,
                        target: seed.a, deadline: replayDeadline) { grants in
                        await pairExecution(executor: executor, wire: unknownWire, grants: grants,
                            deadline: replayDeadline)
                    }
                    #expect(replay.messageID == durableUnknown.messageID)
                    #expect(try await pairForwardCount(sql: sql,
                        operation: unknownWire.operationID.uuidValue!) == 1)
                    #expect(await hosted.budget.snapshot().commandCount == 0)
                    let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
                    try await placement.retireAfterDrain(proof, shards: ["room-a"])
                } catch {
                    await firstSQLGate.open()
                    let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
                    try await placement.retireAfterDrain(proof, shards: ["room-a"])
                    throw error
                }
            }
        }
    }
}

private let pairRoomBUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

private struct PairSeed: Sendable {
    let a: RoomID
    let b: RoomID
    let aSource: V2AcceptedMessage
    let bSource: V2AcceptedMessage
    let profile: V2CapacityProfile
}

private struct PairHosted: Sendable {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
    let admission: V2DatabaseWorkAdmissionController
    let configuration: V2RoomRuntimeConfiguration
    let tokens: PairTokenRegistry
}

private actor PairTokenRegistry {
    private var values: [RoomID: V2RoomActivationToken] = [:]
    func set(_ token: V2RoomActivationToken) { values[token.roomID] = token }
    func get(_ room: RoomID) -> V2RoomActivationToken? { values[room] }
}

private func makePairHost(database: any Database, profile: V2CapacityProfile,
    identity: V2ActorHostIdentity, placement: V2RoomActorPlacementRuntime,
    policies: V2RoomPolicyAuthorizationService) throws -> PairHosted {
    // Four reservation permits allow one pair to hold two barriers while an
    // opposing pair queues on A; only two rooms are actually activated.
    let config = try V2RoomRuntimeConfiguration(maximumActiveRooms: 4,
        maximumConcurrentRestores: 2, maximumPendingActivations: 2,
        maximumConcurrentReservations: 4)
    let budget = V2RoomCommandBudget(configuration: config)
    let admission = V2DatabaseWorkAdmissionController(policy: .init(
        maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
        maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
        maximumInteractiveReadQueued: 2, maximumSyncQueued: 1,
        timeout: .seconds(2)))
    let writes = PostgresV2RoomWriteStore(database: database)
    let resources = try V2RoomServerOwnerResources(database: database, initializationDatabase: database, sendDatabase: try v2FixtureMessageWriteDatabase(database, capacity: 1), writes: writes,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
        receiptProjectionDelivery: PairProjectionDelivery(), capacityProfile: profile,
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init(),
        databaseWorkAdmission: admission)
    let factory = try V2RoomServerActivationFactory(owners: ["room-a": resources.usingPolicyAuthorizations(policies)],
        safetyActorUserID: senderID).runtimeFactory()
    return .init(host: .init(identity: identity, placement: placement,
        configuration: config, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory),
        budget: budget, admission: admission, configuration: config,
        tokens: PairTokenRegistry())
}

private func activatePair(host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
    seed: PairSeed, into tokens: PairTokenRegistry) async throws {
    let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
    for room in [seed.a, seed.b] {
        guard case .ready(let token) = try await host.activate(roomID: room,
            owner: owner, deadline: .now + .seconds(8)) else { throw PairTestFailure.notReady }
        await tokens.set(token)
    }
}

private func pairCoordinator(host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>,
    configuration: V2RoomRuntimeConfiguration, tokens: PairTokenRegistry,
    trace: PairReservationTrace) -> V2RoomReservationCoordinator {
    .init(operations: .init(
        reserve: { room, request, deadline in
            await trace.attempt(room: room, request: request)
            guard let token = await tokens.get(room) else { throw PairTestFailure.notReady }
            let grant = try await host.reserve(token: token, requestID: request, deadline: deadline)
            await trace.granted(room: room, request: request)
            return grant
        }, markDispatched: { grant, _ in try await host.markReservationDispatched(grant) },
        abort: { grant, _ in await host.abortReservation(grant) },
        finish: { grant, completion, _ in
            await host.finishReservation(grant, completion: completion)
        }), configuration: configuration)
}

private func pairExecutor(database: any Database, profile: V2CapacityProfile,
    admission: V2DatabaseWorkAdmissionController,
    policies: V2RoomPolicyAuthorizationService) throws -> V2ActorForwardPairDomainExecutor {
    .init(database: database, write: PostgresV2RoomWriteStore(database: database).usingPolicyAuthorizations(policies), capacityProfile: profile,
        limits: try .init(maxUTF8Bytes: 64), databaseWorkAdmission: admission, now: Date.init)
}

private func pairWire(sourceRoom: RoomID, targetRoom: RoomID,
    sourceMessage: MessageID) -> V2ActorForwardPairWire {
    .init(actorUserID: senderID, operationID: .init(uuid: UUID()),
        source: try! .init(roomID: sourceRoom, messageID: sourceMessage,
            revision: .init(1)), targetRoomID: targetRoom)
}

private func pairExecution(executor: V2ActorForwardPairDomainExecutor,
    wire: V2ActorForwardPairWire, grants: [V2RoomReservation],
    deadline: ContinuousClock.Instant) async
    -> V2RoomTransactionCompletion<V2ActorForwardMessageResultWire> {
    do { return .committed(try await executor.execute(wire,
        activationTokens: grants.map(\.token), deadline: deadline)) }
    catch { return v2RoomDomainCompletion(error) }
}

private func recoveryBytes(_ room: RoomID) throws -> V2RoomRequest {
    try V2RoomRequest.recovery(.init(roomID: room,
        actorUserID: senderID, kind: .state))
}

private func recoveryHead(_ response: V2RoomResponse, room: RoomID) throws -> UInt64 {
    guard case .recovery(.state(.state(let state))) = response,
          state.roomID == room else { throw PairTestFailure.badRecovery }
    return state.head
}

private func pairRoomHead(sql: any SQLDatabase, room: RoomID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id = \(bind: room.uuidValue!)
        """).first(decoding: PairCountRow.self)).value
}

private func pairForwardCount(sql: any SQLDatabase, operation: UUID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.message_forward_operations
        WHERE operation_id = \(bind: operation)
        """).first(decoding: PairCountRow.self)).value
}

private struct PairCountRow: Decodable { let value: Int64 }
private struct PairBoolRow: Decodable { let value: Bool }
private enum PairTestFailure: Error { case notReady, badRecovery, phaseTimeout, schemaAlreadyExists }

private actor PairReservationTrace {
    private var order: [UUID] = []
    private var attempts: [UUID: [RoomID]] = [:]
    private var grants: [UUID: [RoomID]] = [:]

    func attempt(room: RoomID, request: UUID) {
        if attempts[request] == nil { order.append(request) }
        attempts[request, default: []].append(room)
    }
    func granted(room: RoomID, request: UUID) { grants[request, default: []].append(room) }
    func requestIDs() -> [UUID] { order }
    func attempted(for request: UUID) -> [RoomID] { attempts[request] ?? [] }
    func acquired(for request: UUID) -> [RoomID] { grants[request] ?? [] }
    func waitForRequests(_ count: Int) async throws {
        try await pairWaitUntil { await self.requestIDs().count >= count }
    }
    func waitForAttempt(_ room: RoomID) async throws {
        try await pairWaitUntil { await self.hasAttempt(room) }
    }
    func waitForGranted(_ room: RoomID) async throws {
        try await pairWaitUntil { await self.hasGrant(room) }
    }
    private func hasAttempt(_ room: RoomID) -> Bool {
        attempts.values.contains { $0.contains(room) }
    }
    private func hasGrant(_ room: RoomID) -> Bool {
        grants.values.contains { $0.contains(room) }
    }
}

private actor PairCommittedOutcome {
    private var outcome: V2ActorForwardMessageResultWire?
    func record(_ value: V2ActorForwardMessageResultWire) { outcome = value }
    func value() -> V2ActorForwardMessageResultWire? { outcome }
}

private func pairExpectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private actor PairPhaseGate {
    private var held: CheckedContinuation<Void, Never>?
    private var entered = false
    private var opened = false

    func hold() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { held = $0 }
    }
    func waitUntilHeld() async throws {
        try await pairWaitUntil { await self.isEntered() }
    }
    private func isEntered() -> Bool { entered }
    func open() {
        opened = true
        held?.resume()
        held = nil
    }
}

private func pairWaitUntil(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw PairTestFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct PairProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private func withPairDatabase(_ operation: (any Database, any SQLDatabase, PairSeed, V2RoomPolicyAuthorizationService) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_IS_DISPOSABLE"] == "1" else {
        throw PairTestFailure.schemaAlreadyExists
    }
    let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_PAIR_INTERLEAVE_DATABASE_URL"])
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: PairBoolRow.self)?.value == false else {
            throw PairTestFailure.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(on: sql)
        let at = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("""
            INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
            VALUES (\(bind: pairRoomBUUID), 'room-a', 'standard', 'standard')
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_owner_routes
                (room_id, room_shard_id, route_epoch, created_at, updated_at)
            VALUES (\(bind: pairRoomBUUID), 'room-a', 0, \(bind: at), \(bind: at))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
            VALUES (\(bind: pairRoomBUUID), \(bind: senderUUID), 'Pair target', \(bind: at))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_admission
                (room_id, eligible_member_count, command_window_limit,
                 shard_lease_id, shard_lease_generation)
            VALUES (\(bind: pairRoomBUUID), 3, 10, \(bind: leaseUUID), 1)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: pairRoomBUUID), \(bind: senderUUID), 0),
                   (\(bind: pairRoomBUUID), \(bind: memberTwoUUID), 0),
                   (\(bind: pairRoomBUUID), \(bind: memberThreeUUID), 0)
            """).run()
        // Seed sources at the same positive membership generation that the
        // concrete recovery reader and forwarding visibility predicate use.
        try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 1").run()
        try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
        let profile = try fixture.forwardImportTestProfile()
        let sender = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(
            database: database, controlDatabase: database,
            store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
            capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { at })
        let b = RoomID(uuid: pairRoomBUUID)
        guard case .accepted(let sourceA) = try await sender.send(.init(roomID: roomID,
            actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "source A")),
              case .accepted(let sourceB) = try await sender.send(.init(roomID: b,
            actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "source B")) else {
            throw PairTestFailure.notReady
        }
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET valid_until = clock_timestamp() + INTERVAL '1 hour'
            WHERE room_shard_id = 'room-a'
            """).run()
        try await withFixturePolicyOwners(database: database, projectionDelivery: PairProjectionDelivery()) { owners in
            let policies = V2RoomPolicyAuthorizationService(roomDatabase: database,
                policyOwners: owners, endpoint: "pair-reservation-test", maximumRooms: 2)
            do {
                try await operation(database, sql, .init(a: roomID, b: b,
                    aSource: sourceA, bSource: sourceB, profile: profile), policies)
                await policies.shutdown()
            } catch {
                await policies.shutdown()
                throw error
            }
        }
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
