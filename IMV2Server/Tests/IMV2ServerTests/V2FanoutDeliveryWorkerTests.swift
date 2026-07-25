import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 fan-out delivery worker")
struct V2FanoutDeliveryWorkerTests {
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

    @Test("a stale lease is not retried or live-notified")
    func staleLeaseDoesNotNotify() async throws {
        let store = DeliveryStore(lease: try fixtureLease(), commit: .staleLease)
        let notifier = RecordingNotifier()
        let worker = V2FanoutDeliveryWorker(store: store, liveNotifier: notifier)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, committedCount: 0, staleCount: 1, releasedCount: 0))
        #expect(await notifier.hints().isEmpty)
        #expect(await store.releaseCount() == 0)
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

    func claimPending(bucket: String?, now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2FanoutDeliveryLease] {
        self.bucket = bucket
        guard !claimed else { return [] }
        claimed = true
        return [lease]
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) throws -> V2FanoutDeliveryCommit {
        if shouldFail { throw DeliveryFailure.failed }
        return outcome ?? .staleLease
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
    func claimedBucket() -> String? { bucket }
    func handoffs() -> [V2UserShardRoute] { routed }
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
