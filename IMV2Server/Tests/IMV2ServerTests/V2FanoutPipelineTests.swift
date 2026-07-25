import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 fan-out pipeline")
struct V2FanoutPipelineTests {
    @Test("one bounded run progresses durable outbox publication and delivery")
    func runOnceProgressesBothStages() async throws {
        let trigger = try V2FanoutPlanTrigger(
            sourceEventID: .init("00000000-0000-0000-0000-000000000601"),
            planID: .init("00000000-0000-0000-0000-000000000602")
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let outbox = PipelineOutboxStore(trigger: trigger)
        let planStore = PipelinePlanStore()
        let deliveryStore = PipelineDeliveryStore(lease: try .init(
            sourceEventID: trigger.sourceEventID,
            targetUserID: .init("00000000-0000-0000-0000-000000000603"),
            projectionKind: "message_created",
            completionUnitID: .init("00000000-0000-0000-0000-000000000604"),
            observedRoute: try .init(bucket: "users-primary", observedRouterEpoch: 1),
            claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000605")!
        ))
        let telemetry = V2InMemoryTelemetrySink()
        let pipeline = V2FanoutPipeline(
            relay: .init(
                store: outbox,
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: planStore, pageSize: 64, now: { now })),
                now: { now }
            ),
            deliveryWorker: .init(store: deliveryStore, now: { now }),
            telemetry: telemetry,
            now: { now }
        )

        let report = try await pipeline.runOnce(limit: 8)

        #expect(report.relay == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))
        #expect(report.delivery == .init(claimedCount: 1, committedCount: 1, staleCount: 0, releasedCount: 0))
        #expect(await planStore.triggers() == [trigger])
        #expect(await outbox.didPublish())
        #expect(await deliveryStore.didCommit())
        let events = await telemetry.events()
        #expect(events.count == 1)
        guard case .fanoutProgress(_, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0) = try #require(events.first) else {
            Issue.record("expected aggregate fan-out metric without room or user labels")
            return
        }
    }

    @Test("planner and delivery concurrency caps run independent bounded claims and aggregate one report")
    func runOnceUsesIndependentStageConcurrency() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_100)
        let triggers = try [
            V2FanoutPlanTrigger(sourceEventID: .init("00000000-0000-0000-0000-000000000611"), planID: .init("00000000-0000-0000-0000-000000000612")),
            V2FanoutPlanTrigger(sourceEventID: .init("00000000-0000-0000-0000-000000000613"), planID: .init("00000000-0000-0000-0000-000000000614")),
        ]
        let outbox = ConcurrentPipelineOutboxStore(triggers: triggers)
        let plannerStore = ConcurrentPipelinePlanStore()
        let deliveryStore = ConcurrentPipelineDeliveryStore(leases: try [
            makeConcurrentDeliveryLease(userSuffix: "615"),
            makeConcurrentDeliveryLease(userSuffix: "616"),
            makeConcurrentDeliveryLease(userSuffix: "617"),
        ])
        let telemetry = V2InMemoryTelemetrySink()
        let pipeline = V2FanoutPipeline(
            relay: .init(
                store: outbox,
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: plannerStore, pageSize: 64, now: { now })),
                now: { now }
            ),
            deliveryWorker: .init(store: deliveryStore, now: { now }),
            telemetry: telemetry,
            now: { now }
        )

        let report = try await pipeline.runOnce(limit: 1, plannerConcurrency: 2, deliveryConcurrency: 3)

        #expect(report.relay == .init(claimedCount: 2, publishedCount: 2, releasedCount: 0))
        #expect(report.delivery == .init(claimedCount: 3, committedCount: 3, staleCount: 0, releasedCount: 0))
        #expect(await plannerStore.plannedCount() == 2)
        #expect(await deliveryStore.committedCount() == 3)
        let events = await telemetry.events()
        guard case .fanoutProgress(_, 2, 2, 0, 0, 3, 3, 0, 0, 0, 0, 0) = try #require(events.first) else {
            Issue.record("expected one aggregate fan-out metric for all bounded workers")
            return
        }
    }

    @Test("idle polls return a zero report without emitting a zero-work telemetry event")
    func idleRunIsTelemetrySilent() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_200)
        let telemetry = V2InMemoryTelemetrySink()
        let pipeline = V2FanoutPipeline(
            relay: .init(
                store: ConcurrentPipelineOutboxStore(triggers: []),
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: ConcurrentPipelinePlanStore(), pageSize: 64, now: { now })),
                now: { now }
            ),
            deliveryWorker: .init(store: ConcurrentPipelineDeliveryStore(leases: []), now: { now }),
            telemetry: telemetry,
            now: { now }
        )

        let report = try await pipeline.runOnce(limit: 8)

        #expect(report.relay == .init(claimedCount: 0, publishedCount: 0, releasedCount: 0))
        #expect(report.delivery == .init(claimedCount: 0, committedCount: 0, staleCount: 0, releasedCount: 0))
        #expect(await telemetry.events().isEmpty)
    }

    @Test("configured delivery buckets each receive a bounded claim pass under one global cap")
    func runOnceDrainsEveryConfiguredBucket() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_300)
        let store = BucketedPipelineDeliveryStore(leases: try [
            "users-a": makeBucketedDeliveryLease(bucket: "users-a", userSuffix: "621"),
            "users-b": makeBucketedDeliveryLease(bucket: "users-b", userSuffix: "622"),
        ])
        let pipeline = V2FanoutPipeline(
            relay: .init(
                store: ConcurrentPipelineOutboxStore(triggers: []),
                publisher: V2LocalFanoutPlanPublisher(planner: .init(store: ConcurrentPipelinePlanStore(), pageSize: 64, now: { now })),
                now: { now }
            ),
            deliveryWorkers: [
                .init(store: store, bucket: "users-a", now: { now }),
                .init(store: store, bucket: "users-b", now: { now }),
            ],
            now: { now }
        )

        let report = try await pipeline.runOnce(limit: 1, plannerConcurrency: 1, deliveryConcurrency: 1)
        #expect(report.delivery == .init(claimedCount: 2, committedCount: 2, staleCount: 0, releasedCount: 0))
        #expect(await store.claimedBuckets() == ["users-a", "users-b"])
        #expect(await store.committedCount() == 2)
    }
}

private actor PipelineOutboxStore: V2RoomOutboxStore {
    private let trigger: V2FanoutPlanTrigger
    private var claimed = false
    private var published = false

    init(trigger: V2FanoutPlanTrigger) { self.trigger = trigger }

    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2OutboxLease] {
        guard !claimed else { return [] }
        claimed = true
        return [.init(trigger: trigger, claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000606")!)]
    }

    func markPublished(_: V2OutboxLease) { published = true }
    func release(_: V2OutboxLease) { claimed = false }
    func didPublish() -> Bool { published }
}

private actor PipelinePlanStore: V2FanoutPlanStore {
    private var planned: [V2FanoutPlanTrigger] = []

    func plan(_ trigger: V2FanoutPlanTrigger, pageSize _: Int, now _: Date) -> V2FanoutPlanningResult {
        planned.append(trigger)
        return .init(createdCompletionUnits: 1, createdDeliveries: 1, wasAlreadyPlanned: false)
    }

    func triggers() -> [V2FanoutPlanTrigger] { planned }
}

private actor PipelineDeliveryStore: V2FanoutDeliveryStore {
    private let lease: V2FanoutDeliveryLease
    private var claimed = false
    private var committed = false

    init(lease: V2FanoutDeliveryLease) { self.lease = lease }

    func claimPending(bucket _: String?, now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2FanoutDeliveryLease] {
        guard !claimed else { return [] }
        claimed = true
        return [lease]
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) -> V2FanoutDeliveryCommit {
        committed = true
        return .committed(userSyncSequence: 1, releasedCompletionUnit: true, closedPlan: true)
    }

    func release(_: V2FanoutDeliveryLease) { claimed = false }
    func didCommit() -> Bool { committed }
}

private actor ConcurrentPipelineOutboxStore: V2RoomOutboxStore {
    private var pending: [V2FanoutPlanTrigger]

    init(triggers: [V2FanoutPlanTrigger]) { pending = triggers }

    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2OutboxLease] {
        let claimed = Array(pending.prefix(limit))
        pending.removeFirst(claimed.count)
        return claimed.map { .init(trigger: $0, claimToken: UUID()) }
    }

    func markPublished(_: V2OutboxLease) {}
    func release(_ lease: V2OutboxLease) { pending.append(lease.trigger) }
}

private actor ConcurrentPipelinePlanStore: V2FanoutPlanStore {
    private var planned = 0

    func plan(_: V2FanoutPlanTrigger, pageSize _: Int, now _: Date) -> V2FanoutPlanningResult {
        planned += 1
        return .init(createdCompletionUnits: 1, createdDeliveries: 1, wasAlreadyPlanned: false)
    }

    func plannedCount() -> Int { planned }
}

private actor ConcurrentPipelineDeliveryStore: V2FanoutDeliveryStore {
    private var pending: [V2FanoutDeliveryLease]
    private var committed = 0

    init(leases: [V2FanoutDeliveryLease]) { pending = leases }

    func claimPending(bucket _: String?, now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2FanoutDeliveryLease] {
        let claimed = Array(pending.prefix(limit))
        pending.removeFirst(claimed.count)
        return claimed
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) -> V2FanoutDeliveryCommit {
        committed += 1
        return .committed(userSyncSequence: UInt64(committed), releasedCompletionUnit: false, closedPlan: false)
    }

    func release(_ lease: V2FanoutDeliveryLease) { pending.append(lease) }
    func committedCount() -> Int { committed }
}

private actor BucketedPipelineDeliveryStore: V2FanoutDeliveryStore {
    private var pending: [String: [V2FanoutDeliveryLease]]
    private var claimed: [String] = []
    private var committed = 0

    init(leases: [String: V2FanoutDeliveryLease]) {
        pending = leases.mapValues { [$0] }
    }

    func claimPending(bucket: String?, now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2FanoutDeliveryLease] {
        guard let bucket else { return [] }
        claimed.append(bucket)
        let values = Array((pending[bucket] ?? []).prefix(limit))
        pending[bucket]?.removeFirst(values.count)
        return values
    }

    func commit(_: V2FanoutDeliveryLease, now _: Date) -> V2FanoutDeliveryCommit {
        committed += 1
        return .committed(userSyncSequence: UInt64(committed), releasedCompletionUnit: false, closedPlan: false)
    }

    func release(_: V2FanoutDeliveryLease) {}
    func claimedBuckets() -> [String] { claimed }
    func committedCount() -> Int { committed }
}

private func makeConcurrentDeliveryLease(userSuffix: String) throws -> V2FanoutDeliveryLease {
    try .init(
        sourceEventID: .init("00000000-0000-0000-0000-000000000618"),
        targetUserID: .init("00000000-0000-0000-0000-000000000\(userSuffix)"),
        projectionKind: "message",
        completionUnitID: .init("00000000-0000-0000-0000-000000000619"),
        observedRoute: .init(bucket: "users-primary", observedRouterEpoch: 1),
        claimToken: UUID()
    )
}

private func makeBucketedDeliveryLease(bucket: String, userSuffix: String) throws -> V2FanoutDeliveryLease {
    try .init(
        sourceEventID: .init("00000000-0000-0000-0000-000000000620"),
        targetUserID: .init("00000000-0000-0000-0000-000000000\(userSuffix)"),
        projectionKind: "message",
        completionUnitID: .init("00000000-0000-0000-0000-000000000623"),
        observedRoute: .init(bucket: bucket, observedRouterEpoch: 1),
        claimToken: UUID()
    )
}
