import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 outbox relay")
struct V2OutboxRelayTests {
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
