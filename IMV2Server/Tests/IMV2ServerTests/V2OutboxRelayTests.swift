import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 outbox relay")
struct V2OutboxRelayTests {
    @Test("Invalid retry clocks preserve scalar and batch outbox leases", arguments: [false, true], Array(0...8))
    func invalidRetryClockDoesNotRelease(batch: Bool, boundary: Int) async throws {
        let clock = V2WorkerRetryClockFixture(boundary)
        let triggers = try (0..<(batch ? 2 : 1)).map { _ in
            try makeTrigger(event: UUID().uuidString, plan: UUID().uuidString)
        }
        let store = RetryBoundaryOutboxStore(triggers: triggers)
        let relay = V2OutboxRelay(store: store, publisher: RetryBoundaryPublisher(), retryPolicy: clock.policy, now: { clock.now() })
        await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await relay.runOnce(limit: 2) }
        #expect(await store.recorded.isEmpty)
        let recoveredAt = Date(timeIntervalSince1970: 1_750_000_010)
        let recovered = V2OutboxRelay(store: store, publisher: RetryBoundaryPublisher(),
            retryPolicy: .init(initialDelay: 0.5, maximumDelay: 0.5, maximumAttempts: 3, jitterFraction: 0), now: { recoveredAt })
        #expect(try await recovered.runOnce(limit: 2).releasedCount == triggers.count)
        #expect(await store.recorded == Array(repeating: .retry(at: recoveredAt.addingTimeInterval(0.5)), count: triggers.count))
    }

    @Test("successful publication marks the exact durable lease published")
    func successfulPublication() async throws {
        let trigger = try makeTrigger(event: "00000000-0000-0000-0000-000000000101", plan: "00000000-0000-0000-0000-000000000102")
        let store = InMemoryV2OutboxStore(triggers: [trigger])
        let publisher = RecordingPublisher()
        let relay = V2OutboxRelay(store: store, publisher: publisher, now: { Date(timeIntervalSince1970: 1_750_000_000) })

        let report = try await relay.runOnce(limit: 8)

        #expect(report == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))
        #expect(await publisher.triggers() == [trigger])
        #expect(await store.publishedTriggers() == [trigger])
    }

    @Test("failed publication releases the lease so a later relay can retry")
    func failedPublicationIsRetryable() async throws {
        let trigger = try makeTrigger(event: "00000000-0000-0000-0000-000000000103", plan: "00000000-0000-0000-0000-000000000104")
        let store = InMemoryV2OutboxStore(triggers: [trigger])
        let failingRelay = V2OutboxRelay(store: store, publisher: FailingPublisher(), now: { Date(timeIntervalSince1970: 1_750_000_000) })
        #expect(try await failingRelay.runOnce(limit: 1) == .init(claimedCount: 1, publishedCount: 0, releasedCount: 1))

        let publisher = RecordingPublisher()
        let retryRelay = V2OutboxRelay(store: store, publisher: publisher, now: { Date(timeIntervalSince1970: 1_750_000_001) })
        #expect(try await retryRelay.runOnce(limit: 1) == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))
        #expect(await store.publishedTriggers() == [trigger])
    }

    @Test("retry exhaustion pauses source work instead of treating it as published")
    func retryExhaustionPausesOutbox() async throws {
        let trigger = try makeTrigger(event: "00000000-0000-0000-0000-000000000105", plan: "00000000-0000-0000-0000-000000000106")
        let store = PausingOutboxStore(trigger: trigger, attempt: 2)
        let relay = V2OutboxRelay(
            store: store,
            publisher: FailingPublisher(),
            retryPolicy: .init(initialDelay: 1, maximumDelay: 10, maximumAttempts: 2, jitterFraction: 0),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        #expect(try await relay.runOnce(limit: 1) == .init(claimedCount: 1, publishedCount: 0, releasedCount: 0, pausedCount: 1))
        #expect(await store.dispositions() == [.pause])
    }

    @Test("retry backoff is deterministic, bounded, and only pauses at the configured limit")
    func retryPolicyIsDeterministic() {
        let policy = V2DurableRetryPolicy(initialDelay: 10, maximumDelay: 100, maximumAttempts: 3, jitterFraction: 0.2)
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        guard case let .retry(at: first) = policy.disposition(attempt: 1, claimToken: token, now: now),
              case let .retry(at: repeated) = policy.disposition(attempt: 1, claimToken: token, now: now),
              case let .retry(at: second) = policy.disposition(attempt: 2, claimToken: token, now: now)
        else {
            Issue.record("expected retries before the configured attempt limit")
            return
        }
        #expect(first == repeated)
        #expect(first.timeIntervalSince(now) >= 8)
        #expect(first.timeIntervalSince(now) <= 12)
        #expect(second.timeIntervalSince(now) >= 16)
        #expect(second.timeIntervalSince(now) <= 24)
        #expect(policy.disposition(attempt: 3, claimToken: token, now: now) == .pause)
    }

    @Test("broker hint loss cannot release durable outbox work")
    func bestEffortHintFailureStillPublishesDurableWork() async throws {
        let trigger = try makeTrigger(event: "00000000-0000-0000-0000-000000000109", plan: "00000000-0000-0000-0000-000000000110")
        let store = InMemoryV2OutboxStore(triggers: [trigger])
        let durable = RecordingPublisher()
        let relay = V2OutboxRelay(
            store: store,
            publisher: V2BestEffortFanoutPlanHintPublisher(durablePublisher: durable, hintPublisher: FailingHintPublisher()),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        #expect(try await relay.runOnce(limit: 1) == .init(claimedCount: 1, publishedCount: 1, releasedCount: 0))
        #expect(await durable.triggers() == [trigger])
        #expect(await store.publishedTriggers() == [trigger])
    }

    @Test("a multi-lease claim uses one native planning batch and one fenced acknowledgement batch")
    func nativeBatchPublication() async throws {
        let triggers = try [
            makeTrigger(event: "00000000-0000-0000-0000-000000000111", plan: "00000000-0000-0000-0000-000000000112"),
            makeTrigger(event: "00000000-0000-0000-0000-000000000113", plan: "00000000-0000-0000-0000-000000000114"),
        ]
        let store = BatchRecordingOutboxStore(triggers: triggers)
        let publisher = BatchRecordingPublisher()
        let relay = V2OutboxRelay(
            store: store,
            publisher: publisher,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )

        #expect(try await relay.runOnce(limit: 8) == .init(
            claimedCount: 2,
            publishedCount: 2,
            releasedCount: 0
        ))
        #expect(await publisher.batches() == [triggers])
        #expect(await publisher.scalarPublishCount() == 0)
        #expect(await store.publishedBatches() == [triggers])
        #expect(await store.scalarPublishCount() == 0)
    }

}

private actor RecordingPublisher: V2FanoutPlanPublisher {
    private var published: [V2FanoutPlanTrigger] = []
    func publish(_ trigger: V2FanoutPlanTrigger) { published.append(trigger) }
    func triggers() -> [V2FanoutPlanTrigger] { published }
}

private struct FailingPublisher: V2FanoutPlanPublisher {
    func publish(_: V2FanoutPlanTrigger) throws { throw RelayError.publishFailed }
    private enum RelayError: Error { case publishFailed }
}

private struct FailingHintPublisher: V2FanoutPlanHintPublishing {
    func publishHint(_: V2FanoutPlanTrigger) throws { throw Failure.unavailable }
    private enum Failure: Error { case unavailable }
}

private actor BatchRecordingPublisher: V2BatchFanoutPlanPublisher {
    private var recordedBatches: [[V2FanoutPlanTrigger]] = []
    private var scalarCount = 0

    func publish(_: V2FanoutPlanTrigger) { scalarCount += 1 }
    func publishBatch(_ triggers: [V2FanoutPlanTrigger]) { recordedBatches.append(triggers) }
    func batches() -> [[V2FanoutPlanTrigger]] { recordedBatches }
    func scalarPublishCount() -> Int { scalarCount }
}

private actor BatchRecordingOutboxStore: V2BatchRoomOutboxStore {
    private let leases: [V2OutboxLease]
    private var didClaim = false
    private var batches: [[V2FanoutPlanTrigger]] = []
    private var scalarCount = 0

    init(triggers: [V2FanoutPlanTrigger]) {
        leases = triggers.enumerated().map { offset, trigger in
            .init(
                trigger: trigger,
                claimToken: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", offset + 1))!
            )
        }
    }

    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2OutboxLease] {
        guard !didClaim else { return [] }
        didClaim = true
        return Array(leases.prefix(limit))
    }

    func markPublished(_: V2OutboxLease) { scalarCount += 1 }
    func markPublished(_ leases: [V2OutboxLease]) { batches.append(leases.map(\.trigger)) }
    func release(_: V2OutboxLease) {}
    func scheduleRetry(_: V2OutboxLease, disposition _: V2DurableRetryDisposition, now _: Date) {}
    func publishedBatches() -> [[V2FanoutPlanTrigger]] { batches }
    func scalarPublishCount() -> Int { scalarCount }
}

private actor PausingOutboxStore: V2RoomOutboxStore {
    private let lease: V2OutboxLease
    private var claimed = false
    private var recorded: [V2DurableRetryDisposition] = []

    init(trigger: V2FanoutPlanTrigger, attempt: Int) {
        lease = .init(trigger: trigger, claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!, attempt: attempt)
    }

    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit _: Int) -> [V2OutboxLease] {
        guard !claimed else { return [] }
        claimed = true
        return [lease]
    }

    func markPublished(_: V2OutboxLease) {}
    func release(_: V2OutboxLease) {}
    func scheduleRetry(_: V2OutboxLease, disposition: V2DurableRetryDisposition, now _: Date) {
        recorded.append(disposition)
    }
    func dispositions() -> [V2DurableRetryDisposition] { recorded }
}

private func makeTrigger(event: String, plan: String) throws -> V2FanoutPlanTrigger {
    try .init(sourceEventID: .init(event), planID: .init(plan))
}

private actor RetryBoundaryOutboxStore: V2RoomOutboxStore {
    let leases: [V2OutboxLease]
    private(set) var recorded: [V2DurableRetryDisposition] = []
    init(triggers: [V2FanoutPlanTrigger]) { leases = triggers.map { .init(trigger: $0, claimToken: UUID()) } }
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2OutboxLease] { Array(leases.prefix(limit)) }
    func markPublished(_ lease: V2OutboxLease) { Issue.record("Failed publication cannot be acknowledged") }
    func release(_ lease: V2OutboxLease) { Issue.record("Failure must use the retry policy") }
    func scheduleRetry(_ lease: V2OutboxLease, disposition: V2DurableRetryDisposition, now: Date) { recorded.append(disposition) }
}
private struct RetryBoundaryPublisher: V2BatchFanoutPlanPublisher {
    enum Failure: Error { case unavailable }
    func publish(_ trigger: V2FanoutPlanTrigger) throws { throw Failure.unavailable }
    func publishBatch(_ triggers: [V2FanoutPlanTrigger]) throws { throw Failure.unavailable }
}
