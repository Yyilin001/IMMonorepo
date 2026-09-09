import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 fan-out delivery worker")
struct V2FanoutDeliveryWorkerTests {
    @Test("Invalid retry clocks keep failed delivery leases unreleased", arguments: Array(0...8))
    func invalidRetryClockDoesNotRelease(_ boundary: Int) async throws {
        let clock = V2WorkerRetryClockFixture(boundary)
        let store = DeliveryStore(lease: try fixtureLease(), failure: true)
        let worker = V2FanoutDeliveryWorker(store: store, retryPolicy: clock.policy, now: { clock.now() })
        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await worker.runOnce(limit: 1) }
        #expect(await store.releaseCount() == 0)
        #expect(await store.scheduledDispositions().isEmpty)
        await store.expireClaimForRecovery()
        let recoveredAt = Date(timeIntervalSince1970: 1_750_000_010)
        let recovered = V2FanoutDeliveryWorker(store: store,
            retryPolicy: .init(initialDelay: 0.5, maximumDelay: 0.5, maximumAttempts: 3, jitterFraction: 0), now: { recoveredAt })
        #expect(try await recovered.runOnce(limit: 1).releasedCount == 1)
        #expect(await store.scheduledDispositions() == [.retry(at: recoveredAt.addingTimeInterval(0.5))])
    }

    @Test("claim scheduler reserves bounded recovery-first turns and alternates recovery classes")
    func schedulesFreshAndRecoveryLanesFairly() async {
        let scheduler = V2FanoutDeliveryClaimScheduler(freshBurstPasses: 2)

        let first = await scheduler.lanesForNextClaim()
        let second = await scheduler.lanesForNextClaim()
        let third = await scheduler.lanesForNextClaim()
        let fourth = await scheduler.lanesForNextClaim()
        let fifth = await scheduler.lanesForNextClaim()
        let sixth = await scheduler.lanesForNextClaim()

        #expect(first == [.fresh, .retryDue, .expiredLease])
        #expect(second == [.fresh, .retryDue, .expiredLease])
        #expect(third == [.retryDue, .expiredLease, .fresh])
        #expect(fourth == [.fresh, .expiredLease, .retryDue])
        #expect(fifth == [.fresh, .expiredLease, .retryDue])
        #expect(sixth == [.expiredLease, .retryDue, .fresh])
    }

    @Test("an empty fresh lane falls through immediately to a due retry lane")
    func fallsThroughToRecoveryWithoutWaitingForAnotherPoll() async throws {
        let lease = try fixtureLease()
        let store = LaneDeliveryStore(lease: lease, claimableLane: .retryDue)
        let worker = V2FanoutDeliveryWorker(store: store)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0))
        #expect(await store.claimedLanes() == [.fresh, .retryDue])
    }

    @Test("a committed delivery creates one live-sync hint after durable projection")
    func commitsAndNotifies() async throws {
        let lease = try fixtureLease()
        let store = DeliveryStore(lease: lease, commit: .committed(userSyncSequence: 42, releasedCompletionUnit: true, closedPlan: false))
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(store: store, bucket: "users-primary", liveNotifier: notifier, now: { .distantPast })

        #expect(try await worker.runOnce(limit: 4) == .init(claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0))
        #expect(await notifier.hints() == [.init(userID: lease.targetUserID, eventID: 42, highWatermark: 42)])
        #expect(await store.releaseCount() == 0)
        #expect(await store.claimedBucket() == "users-primary")
    }

    @Test("fresh direct work commits without a durable claim update")
    func freshDirectCommitBypassesClaim() async throws {
        let lease = try fixtureLease()
        let store = FreshDirectDeliveryStore(
            lease: lease,
            freshCommits: [.init(
                sourceEventID: lease.sourceEventID,
                targetUserID: lease.targetUserID,
                userSyncSequence: 77
            )]
        )
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(
            store: store, bucket: "users-primary", liveNotifier: notifier,
            commitBatchSize: 3
        )

        #expect(try await worker.runOnce(limit: 8) == .init(
            claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0
        ))
        #expect(await store.fastCallCount() == 1)
        #expect(await store.fastLimits() == [3])
        #expect(await store.claimCallCount() == 0)
        #expect(await notifier.hints() == [.init(
            userID: lease.targetUserID, eventID: 77, highWatermark: 77
        )])
    }

    @Test("a failed fresh-direct transaction falls back to retry-fenced delivery")
    func freshDirectFailureFallsBackToRetryProtocol() async throws {
        let store = FreshDirectDeliveryStore(
            lease: try fixtureLease(), freshCommits: [], failFresh: true,
            failGenericCommit: true
        )
        let worker = V2FanoutDeliveryWorker(store: store)

        #expect(try await worker.runOnce(limit: 1) == .init(
            claimedCount: 1, committedCount: 0, staleCount: 0, releasedCount: 1
        ))
        #expect(await store.fastCallCount() == 1)
        #expect(await store.recoveryClaimCallCount() == 1)
        #expect(await store.claimCallCount() == 0)
        #expect(await store.retryCount() == 1)
    }

    @Test("fresh-direct cancellation escapes without recovery or retry writes")
    func freshDirectCancellationDoesNotRecover() async throws {
        let store = FreshDirectDeliveryStore(
            lease: try fixtureLease(), freshCommits: [], cancelFresh: true
        )
        let worker = V2FanoutDeliveryWorker(store: store)

        await #expect(throws: CancellationError.self) {
            try await worker.runOnce(limit: 1)
        }
        #expect(await store.recoveryClaimCallCount() == 0)
        #expect(await store.claimCallCount() == 0)
        #expect(await store.retryCount() == 0)
    }

    @Test("a stale lease is not retried or live-notified")
    func staleLeaseDoesNotNotify() async throws {
        let store = DeliveryStore(lease: try fixtureLease(), commit: .staleLease)
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(store: store, liveNotifier: notifier)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 0, staleCount: 1, releasedCount: 0))
        #expect(await notifier.hints().isEmpty)
        #expect(await store.releaseCount() == 0)
    }

    @Test("a route fence handoff after projection is counted without a live notification")
    func postProjectionRouteFenceHandoffDoesNotNotify() async throws {
        let currentRoute = try V2UserShardRoute(
            bucket: "users-next", observedRouterEpoch: 3,
            readFallbackBucket: "users-primary"
        )
        let store = DeliveryStore(
            lease: try fixtureLease(), commit: .rerouted(currentRoute)
        )
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(store: store, liveNotifier: notifier)

        #expect(try await worker.runOnce(limit: 1) == .init(
            claimedCount: 1, committedCount: 0, staleCount: 0,
            staleRouteCount: 1, releasedCount: 0
        ))
        #expect(await notifier.hints().isEmpty)
    }

    @Test("projection failure releases only the lease for a later retry")
    func failedCommitReleasesLease() async throws {
        let store = DeliveryStore(lease: try fixtureLease(), failure: true)
        let worker = V2FanoutDeliveryWorker(store: store)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 0, staleCount: 0, releasedCount: 1))
        #expect(await store.releaseCount() == 1)
    }

    @Test("retry exhaustion pauses a failing delivery without claiming it terminal")
    func retryExhaustionPausesDelivery() async throws {
        let store = DeliveryStore(lease: try fixtureLease(attempt: 2), failure: true)
        let worker = V2FanoutDeliveryWorker(
            store: store,
            retryPolicy: .init(initialDelay: 1, maximumDelay: 10, maximumAttempts: 2, jitterFraction: 0),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 0, staleCount: 0, releasedCount: 0, pausedCount: 1))
        #expect(await store.scheduledDispositions() == [.pause])
    }

    @Test("a stale router epoch hands one durable effect to the current bucket without committing or terminal skipping")
    func staleRouteIsHandedOffToCurrentBucket() async throws {
        let lease = try fixtureLease()
        let store = DeliveryStore(lease: lease, commit: .committed(userSyncSequence: 42, releasedCompletionUnit: true, closedPlan: false))
        let currentRoute = try V2UserShardRoute(bucket: "users-next", observedRouterEpoch: 3, readFallbackBucket: "users-primary")
        let worker = V2FanoutDeliveryWorker(store: store, router: V2SingleUserShardRouter(route: currentRoute))

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 0, staleCount: 0, staleRouteCount: 1, releasedCount: 0))
        #expect(await store.handoffs() == [currentRoute])
        #expect(await store.releaseCount() == 0)
    }

    @Test("commits eligible deliveries in bounded batches and preserves notification order")
    func commitsInBoundedBatches() async throws {
        let leases = try fixtureLeases(count: 5)
        let store = BatchDeliveryStore(leases: leases)
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(store: store, liveNotifier: notifier, commitBatchSize: 2)

        #expect(try await worker.runOnce(limit: 5) == .init(claimedCount: 5, committedCount: 5, staleCount: 0, releasedCount: 0))
        #expect(await store.batchSizes() == [2, 2, 1])
        #expect((await notifier.hints()).map(\.eventID) == [901, 902, 903, 904, 905])
    }

    @Test("checks the current route once for a bounded delivery claim")
    func checksRoutesInOneOrderedBatch() async throws {
        let leases = try fixtureLeases(count: 3)
        let store = BatchDeliveryStore(leases: leases)
        let router = BatchRouteRecordingRouter(route: try .init(bucket: "users-primary", observedRouterEpoch: 2))
        let worker = V2FanoutDeliveryWorker(store: store, router: router, commitBatchSize: 2)

        #expect(try await worker.runOnce(limit: 3) == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
        #expect(await router.requests() == [leases.map(\.targetUserID)])
        #expect(await store.batchSizes() == [2, 1])
    }

    @Test("a failed atomic batch schedules every member for retry")
    func retriesEveryMemberOfFailedBatch() async throws {
        let leases = try fixtureLeases(count: 3)
        let store = BatchDeliveryStore(leases: leases, failFirstBatch: true)
        let worker = V2FanoutDeliveryWorker(store: store, commitBatchSize: 2)

        #expect(try await worker.runOnce(limit: 3) == .init(claimedCount: 3, committedCount: 1, staleCount: 0, releasedCount: 2))
        #expect(await store.batchSizes() == [2, 1])
        #expect(await store.scheduledTargetUsers() == Array(leases.prefix(2).map(\.targetUserID)))
    }

    @Test("bounded concurrent batch attempts retain source notification order")
    func concurrentBatchAttemptsPreserveNotificationOrder() async throws {
        let leases = try fixtureLeases(count: 5)
        let store = BatchDeliveryStore(leases: leases)
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(
            store: store, liveNotifier: notifier, commitBatchSize: 2,
            maximumConcurrentCommitBatches: 2
        )

        #expect(try await worker.runOnce(limit: 5) == .init(claimedCount: 5, committedCount: 5, staleCount: 0, releasedCount: 0))
        #expect((await notifier.hints()).map(\.eventID) == [901, 902, 903, 904, 905])
    }

    @Test("a failed concurrent batch retries only its own atomic unit")
    func concurrentBatchFailureRetainsItsRetryUnit() async throws {
        let leases = try fixtureLeases(count: 5)
        let store = BatchDeliveryStore(leases: leases, failingTargetUserID: leases[2].targetUserID)
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(
            store: store, liveNotifier: notifier, commitBatchSize: 2,
            maximumConcurrentCommitBatches: 2
        )

        #expect(try await worker.runOnce(limit: 5) == .init(claimedCount: 5, committedCount: 3, staleCount: 0, releasedCount: 2))
        #expect(await store.scheduledTargetUsers() == Array(leases[2...3].map(\.targetUserID)))
        #expect((await notifier.hints()).map(\.eventID) == [901, 902, 905])
    }

    @Test("batch cancellation escapes without scheduling durable retries")
    func batchCancellationDoesNotRetry() async throws {
        let leases = try fixtureLeases(count: 2)
        let store = BatchDeliveryStore(leases: leases, cancelCommit: true)
        let worker = V2FanoutDeliveryWorker(store: store, commitBatchSize: 2)

        await #expect(throws: CancellationError.self) {
            try await worker.runOnce(limit: 2)
        }
        #expect(await store.scheduledTargetUsers().isEmpty)
    }

    @Test("a repeated deterministic batch failure isolates only its poison lease")
    func repeatedBatchFailureIsolatesPoisonLease() async throws {
        let leases = try fixtureLeases(count: 4, attempt: 2)
        let poison = leases[1]
        let store = BatchDeliveryStore(
            leases: leases, failingTargetUserID: poison.targetUserID
        )
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(
            store: store, liveNotifier: notifier, commitBatchSize: 4,
            batchFailureIsolationAttempt: 2
        )

        #expect(try await worker.runOnce(limit: 4) == .init(
            claimedCount: 4, committedCount: 3, staleCount: 0,
            releasedCount: 1
        ))
        #expect(await store.batchSizes() == [4, 2, 1, 1, 2])
        #expect(await store.scheduledTargetUsers() == [poison.targetUserID])
        #expect((await notifier.hints()).map(\.eventID) == [901, 903, 904])
    }

    private func fixtureLease(attempt: Int = 1) throws -> V2FanoutDeliveryLease {
        try .init(
            sourceEventID: .init("00000000-0000-0000-0000-000000000801"),
            targetUserID: .init("00000000-0000-0000-0000-000000000802"),
            projectionKind: "message_created",
            completionUnitID: .init("00000000-0000-0000-0000-000000000803"),
            observedRoute: try .init(bucket: "users-primary", observedRouterEpoch: 2),
            claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000804")!,
            attempt: attempt
        )
    }

    private func fixtureLeases(count: Int, attempt: Int = 1) throws -> [V2FanoutDeliveryLease] {
        try (1...count).map { index in
            let suffix = String(format: "%012d", 900 + index)
            return .init(
                sourceEventID: try .init("00000000-0000-0000-0000-000000000801"),
                targetUserID: try .init("00000000-0000-0000-0000-\(suffix)"),
                projectionKind: "message_created",
                completionUnitID: try .init("00000000-0000-0000-0000-000000000803"),
                observedRoute: try .init(bucket: "users-primary", observedRouterEpoch: 2),
                claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000804")!,
                attempt: attempt
            )
        }
    }
}

private actor BatchDeliveryStore: V2FanoutDeliveryStore {
    private let leases: [V2FanoutDeliveryLease]
    private var claimed = false
    private var sizes: [Int] = []
    private var scheduled: [UserID] = []
    private var failFirstBatch: Bool
    private let failingTargetUserID: UserID?
    private let cancelCommit: Bool

    init(
        leases: [V2FanoutDeliveryLease], failFirstBatch: Bool = false,
        failingTargetUserID: UserID? = nil, cancelCommit: Bool = false
    ) {
        self.leases = leases
        self.failFirstBatch = failFirstBatch
        self.failingTargetUserID = failingTargetUserID
        self.cancelCommit = cancelCommit
    }

    func claimPending(bucket _: String?, lane _: V2FanoutDeliveryClaimLane, now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2FanoutDeliveryLease] {
        guard !claimed else { return [] }
        claimed = true
        return leases
    }

    func commit(_ lease: V2FanoutDeliveryLease, now _: Date) -> V2FanoutDeliveryCommit {
        .committed(userSyncSequence: UInt64(String(lease.targetUserID.rawValue.suffix(3))) ?? 0, releasedCompletionUnit: false, closedPlan: false)
    }

    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit] {
        sizes.append(leases.count)
        if cancelCommit { throw CancellationError() }
        if failFirstBatch {
            failFirstBatch = false
            throw DeliveryFailure.failed
        }
        if let failingTargetUserID, leases.contains(where: { $0.targetUserID == failingTargetUserID }) {
            throw DeliveryFailure.failed
        }
        var commits: [V2FanoutDeliveryCommit] = []
        commits.reserveCapacity(leases.count)
        for lease in leases {
            commits.append(commit(lease, now: now))
        }
        return commits
    }

    func release(_: V2FanoutDeliveryLease) {}

    func handoff(_ lease: V2FanoutDeliveryLease, to _: V2UserShardRoute) { release(lease) }

    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition _: V2DurableRetryDisposition, now _: Date) {
        scheduled.append(lease.targetUserID)
    }

    func batchSizes() -> [Int] { sizes }
    func scheduledTargetUsers() -> [UserID] { scheduled }
}

private actor FreshDirectDeliveryStore: V2FreshDirectFanoutDeliveryStore {
    private let lease: V2FanoutDeliveryLease
    private let freshCommits: [V2FreshDirectFanoutDeliveryCommit]
    private let failFresh: Bool
    private let cancelFresh: Bool
    private let failGenericCommit: Bool
    private var didClaim = false
    private var fastCalls = 0
    private var limits: [Int] = []
    private var claimCalls = 0
    private var recoveryClaimCalls = 0
    private var retries = 0

    init(
        lease: V2FanoutDeliveryLease,
        freshCommits: [V2FreshDirectFanoutDeliveryCommit],
        failFresh: Bool = false,
        cancelFresh: Bool = false,
        failGenericCommit: Bool = false
    ) {
        self.lease = lease
        self.freshCommits = freshCommits
        self.failFresh = failFresh
        self.cancelFresh = cancelFresh
        self.failGenericCommit = failGenericCommit
    }

    func commitFreshDirectPreplanned(
        bucket _: String?, partition _: V2FanoutDeliveryClaimPartition?,
        now _: Date, limit: Int
    ) throws -> [V2FreshDirectFanoutDeliveryCommit] {
        fastCalls += 1
        limits.append(limit)
        if cancelFresh { throw CancellationError() }
        if failFresh { throw DeliveryFailure.failed }
        return freshCommits
    }

    func claimFreshDirectPreplannedForRecovery(
        bucket _: String?, partition _: V2FanoutDeliveryClaimPartition?,
        now _: Date, leaseDuration _: TimeInterval, limit _: Int
    ) -> [V2FanoutDeliveryLease] {
        recoveryClaimCalls += 1
        guard !didClaim else { return [] }
        didClaim = true
        return [lease]
    }

    func claimPending(
        bucket _: String?, lane _: V2FanoutDeliveryClaimLane,
        now _: Date, leaseDuration _: TimeInterval, limit _: Int
    ) -> [V2FanoutDeliveryLease] {
        claimCalls += 1
        guard !didClaim else { return [] }
        didClaim = true
        return [lease]
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) throws
        -> V2FanoutDeliveryCommit
    {
        if failGenericCommit { throw DeliveryFailure.failed }
        return .committed(
            userSyncSequence: 1, releasedCompletionUnit: false, closedPlan: false
        )
    }

    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) throws
        -> [V2FanoutDeliveryCommit]
    {
        try leases.map { try commit($0, now: now) }
    }

    func handoff(_: V2FanoutDeliveryLease, to _: V2UserShardRoute) {}
    func release(_: V2FanoutDeliveryLease) {}
    func scheduleRetry(
        _: V2FanoutDeliveryLease, disposition _: V2DurableRetryDisposition,
        now _: Date
    ) { retries += 1 }

    func fastCallCount() -> Int { fastCalls }
    func fastLimits() -> [Int] { limits }
    func claimCallCount() -> Int { claimCalls }
    func recoveryClaimCallCount() -> Int { recoveryClaimCalls }
    func retryCount() -> Int { retries }
}

private actor BatchRouteRecordingRouter: V2UserShardRouter {
    private let route: V2UserShardRoute
    private var requestedUsers: [[UserID]] = []

    init(route: V2UserShardRoute) { self.route = route }

    func routes(for users: [UserID]) -> [V2UserShardRoute] {
        requestedUsers.append(users)
        return Array(repeating: route, count: users.count)
    }

    func requests() -> [[UserID]] { requestedUsers }
}

private actor DeliveryStore: V2FanoutDeliveryStore {
    private let lease: V2FanoutDeliveryLease
    private let outcome: V2FanoutDeliveryCommit?
    private let shouldFail: Bool
    private var claimed = false
    private var releases = 0
    private var scheduled: [V2DurableRetryDisposition] = []
    private var routed: [V2UserShardRoute] = []
    private var bucket: String?

    init(lease: V2FanoutDeliveryLease, commit: V2FanoutDeliveryCommit? = nil, failure: Bool = false) {
        self.lease = lease
        outcome = commit
        shouldFail = failure
    }

    func claimPending(bucket: String?, lane _: V2FanoutDeliveryClaimLane, now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2FanoutDeliveryLease] {
        self.bucket = bucket
        guard !claimed else { return [] }
        claimed = true
        return [lease]
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) throws -> V2FanoutDeliveryCommit {
        if shouldFail { throw DeliveryFailure.failed }
        return outcome ?? .staleLease
    }

    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) throws -> [V2FanoutDeliveryCommit] {
        try leases.map { try commit($0, now: now) }
    }

    func release(_: V2FanoutDeliveryLease) {
        releases += 1
        claimed = false
    }

    func handoff(_: V2FanoutDeliveryLease, to route: V2UserShardRoute) {
        routed.append(route)
        claimed = false
    }

    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now _: Date) {
        scheduled.append(disposition)
        releases += 1
        claimed = false
    }

    func releaseCount() -> Int { releases }
    func scheduledDispositions() -> [V2DurableRetryDisposition] { scheduled }
    func expireClaimForRecovery() { claimed = false }
    func claimedBucket() -> String? { bucket }
    func handoffs() -> [V2UserShardRoute] { routed }
}

private actor LaneDeliveryStore: V2FanoutDeliveryStore {
    private let lease: V2FanoutDeliveryLease
    private let claimableLane: V2FanoutDeliveryClaimLane
    private var claimed = false
    private var lanes: [V2FanoutDeliveryClaimLane] = []

    init(lease: V2FanoutDeliveryLease, claimableLane: V2FanoutDeliveryClaimLane) {
        self.lease = lease
        self.claimableLane = claimableLane
    }

    func claimPending(bucket _: String?, lane: V2FanoutDeliveryClaimLane, now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2FanoutDeliveryLease] {
        lanes.append(lane)
        guard !claimed, lane == claimableLane else { return [] }
        claimed = true
        return [lease]
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) -> V2FanoutDeliveryCommit {
        .committed(userSyncSequence: 1, releasedCompletionUnit: true, closedPlan: false)
    }

    func release(_: V2FanoutDeliveryLease) {}
    func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) -> [V2FanoutDeliveryCommit] { leases.map { commit($0, now: now) } }
    func handoff(_ lease: V2FanoutDeliveryLease, to _: V2UserShardRoute) { release(lease) }
    func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition _: V2DurableRetryDisposition, now _: Date) { release(lease) }
    func claimedLanes() -> [V2FanoutDeliveryClaimLane] { lanes }
}

private actor RecordingNotifier: V2LiveSyncNotifier {
    struct Hint: Equatable, Sendable {
        let userID: UserID
        let eventID: UInt64
        let highWatermark: UInt64
    }

    private var recorded: [Hint] = []

    func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) {
        recorded.append(.init(userID: userID, eventID: eventID, highWatermark: highWatermark))
    }

    func hints() -> [Hint] { recorded }
}

private enum DeliveryFailure: Error { case failed }
