import Foundation
import Synchronization
import Testing
import SQLKit
import FluentKit
import IMV2Core
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerInfrastructure
@testable import IMV2Server

@Suite("Room subscription failed Owner activation retirement", .serialized)
struct PostgresV2RoomSubscriptionOwnerLifecycleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func transientReadKeepsActivationButGapClosesReleasesAndRestoresNewOwner() async throws {
        try await withUserEventDatabase { database, sql, schema in
            // This fixture installs the core schema without the canonical
            // journal extension. Source snapshots require its control-cut table.
            try await sql.raw("CREATE TABLE \(unsafeRaw: schema).realtime_control_versions(topic_kind text NOT NULL,topic_id text NOT NULL,version bigint NOT NULL,membership_discovery_version bigint NOT NULL DEFAULT 0,session_control_version bigint NOT NULL DEFAULT 0,PRIMARY KEY(topic_kind,topic_id))").run()
            let roomUUID = UUID(), userUUID = UUID()
            let room = RoomID(uuid: roomUUID), user = UserID(uuid: userUUID)
            let dataOwner = try V2RoomDataOwner(shardID: "source", epoch: 0)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES(\(bind: roomUUID),'source','standard')").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: roomUUID),\(bind: userUUID),0)").run()
            let leases = PostgresV2RoomActivationStore(database: database, schema: schema)
            let instances = Mutex([SubscriptionLifecycleInstance]())
            let configuration = try V2RoomRuntimeConfiguration(maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 1,
                maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 1, maximumConcurrentReservations: 2)
            let factory = V2RoomActivationFactory<SubscriptionLifecycleRequest, V2RoomSubscriptionResult> { token in
                let instance = SubscriptionLifecycleInstance(database: database, schema: schema, token: token, user: user)
                instances.withLock { $0.append(instance) }
                return .init(restore: { try await instance.restore(deadline: $0) },
                    execute: { await instance.execute($0) }, invalidateReservation: { _ in }, close: { await instance.close() })
            }
            let host = V2RoomActivationHost(identity: .init(hostID: try .init("subscription-lifecycle"), incarnationID: UUID()),
                leaseStore: leases, configuration: configuration, budget: .init(configuration: configuration),
                classify: { _ in .barrier }, factory: factory)
            await host.start()
            do {
                guard case .ready(let first) = try await host.activate(roomID: room, owner: dataOwner, deadline: .now + .seconds(5)) else {
                    throw V2RoomSubscriptionOwnerError.stale
                }
                let encoder = JSONEncoder()
                guard case .granted(let grant) = try await host.invoke(token: first,
                    encodedRequest: encoder.encode(SubscriptionLifecycleRequest.subscribe), deadline: .now + .seconds(5)) else {
                    throw V2RoomSubscriptionOwnerError.stale
                }
                #expect(grant.fence.activation == first)
                let transient = try await host.invoke(token: first,
                    encodedRequest: encoder.encode(SubscriptionLifecycleRequest.transient), deadline: .now + .seconds(5))
                #expect(transient == .failure(.unavailable))
                #expect(try await leases.locate(roomID: room, owner: dataOwner)?.token == first)
                #expect(instances.withLock { $0.count } == 1)
                // The final committed cursor now contains a source gap. The
                // existing Owner cannot reinterpret current members over it.
                try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence=1 WHERE room_id=\(bind: roomUUID)").run()
                let original = instances.withLock { $0[0] }
                await #expect(throws: V2RoomSubscriptionSourceError.snapshotRequired) { try await original.backgroundDrain() }
                await #expect(throws: V2RoomCallFailure.rolledBack(.staleActivation)) {
                    try await host.invoke(token: first, encodedRequest: encoder.encode(SubscriptionLifecycleRequest.subscribe), deadline: .now + .seconds(5))
                }
                let stopWaiting = ContinuousClock.now + .seconds(5)
                while try await leases.locate(roomID: room, owner: dataOwner) != nil {
                    guard .now < stopWaiting else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
                    try await Task.sleep(for: .milliseconds(10))
                }
                while await host.snapshot().retiringRooms > 0 {
                    guard .now < stopWaiting else { throw V2RoomSubscriptionOwnerError.deadlineExceeded }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(await instances.withLock { $0[0] }.closed)
                guard case .ready(let second) = try await host.activate(roomID: room, owner: dataOwner, deadline: .now + .seconds(5)) else {
                    throw V2RoomSubscriptionOwnerError.stale
                }
                #expect(second.activationEpoch.rawValue == first.activationEpoch.rawValue + 1)
                #expect(instances.withLock { $0.count } == 2)
                guard case .granted(let restored) = try await host.invoke(token: second,
                    encodedRequest: encoder.encode(SubscriptionLifecycleRequest.subscribe), deadline: .now + .seconds(5)) else {
                    throw V2RoomSubscriptionOwnerError.stale
                }
                #expect(restored.fence.activation == second && restored.userBaselineSequence == 1)
                #expect(try await leases.release(token: first) == false)
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
            } catch { _ = await host.stop(deadline: .now + .seconds(5)); throw error }
        }
    }
}

private enum SubscriptionLifecycleRequest: String, Codable, Sendable { case subscribe, transient }
private actor SubscriptionLifecycleInstance {
    let database: any Database; let schema: String; let token: V2RoomActivationToken; let user: UserID
    private var source: SubscriptionLifecycleSource?
    private var owner: V2RoomSubscriptionOwner?
    private(set) var closed = false
    private let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
    init(database: any Database, schema: String, token: V2RoomActivationToken, user: UserID) {
        self.database = database; self.schema = schema; self.token = token; self.user = user
    }
    func restore(deadline: ContinuousClock.Instant) async throws {
        let source = SubscriptionLifecycleSource(underlying: try PostgresV2RoomSubscriptionSource(database: database, activation: token, schema: schema))
        self.source = source
        owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: token.roomID, owner: token.owner, activation: token,
            deadline: deadline, trackedUserIDs: [])
    }
    func execute(_ turn: V2RoomTurn<SubscriptionLifecycleRequest>) async -> V2RoomTransactionCompletion<[V2RoomSubscriptionResult]> {
        guard let owner, let source, let item = turn.items.first else { return .rolledBack(.notReady) }
        do {
            if item.request == .transient { await source.failSnapshotOnce() }
            let grant = try await V2RoomSQLDeadline.withDeadline(item.deadline) {
                try await owner.subscribe(gateway: self.gateway, userID: self.user, token: self.token, deadline: item.deadline)
            }
            return .committed([.granted(.init(fence: grant.fence, memberRevision: grant.memberRevision,
                userBaselineSequence: grant.baselineSequence, remainingLeaseMilliseconds: grant.remainingLeaseMilliseconds))])
        } catch {
            do { return .committed([.failure(try v2RoomSubscriptionFailure(for: error))]) }
            catch { return v2RoomDomainCompletion(error) }
        }
    }
    func backgroundDrain() async throws {
        guard let owner else { throw V2RoomSubscriptionOwnerError.closed }
        let deadline = ContinuousClock.now + .seconds(5)
        _ = try await V2RoomSQLDeadline.withDeadline(deadline) { try await owner.drain(token: self.token, deadline: deadline) }
    }
    func close() async { try? await owner?.close(); closed = true }
}
private actor SubscriptionLifecycleSource: V2RoomSubscriptionSource {
    private enum Transient: Error { case unavailable }
    let underlying: PostgresV2RoomSubscriptionSource
    private var failNext = false
    init(underlying: PostgresV2RoomSubscriptionSource) { self.underlying = underlying }
    func failSnapshotOnce() { failNext = true }
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        if failNext { failNext = false; throw Transient.unavailable }
        return try await underlying.snapshot(roomID: roomID, owner: owner, trackedUserIDs: trackedUserIDs)
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64, trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        try await underlying.read(roomID: roomID, owner: owner, afterRoomSequence: afterRoomSequence, trackedUserIDs: trackedUserIDs, limit: limit)
    }
}
