import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 Hybrid group wake relay")
struct V2GroupEventWakeRelayTests {
    @Test("a newer coalesced revision survives an older successful publication")
    func newerRevisionSurvivesPublishedLease() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d01")
        let store = GroupWakeStoreFake(initial: .init(roomID: roomID, highWatermark: 7))
        let publisher = AdvancingGroupWakePublisher(store: store, replacement: .init(roomID: roomID, highWatermark: 9))
        let relay = V2GroupEventWakeRelay(store: store, publisher: publisher, now: { Date(timeIntervalSince1970: 0) })

        #expect(try await relay.runOnce(limit: 1) == .init(claimed: 1, published: 1, retryScheduled: 0))
        #expect(await publisher.values() == [.init(roomID: roomID, highWatermark: 7)])
        #expect(await store.pendingWake() == .init(roomID: roomID, highWatermark: 9))
    }

    @Test("a failed broker publication schedules retry without losing the coalesced wake")
    func failedPublicationSchedulesRetry() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d02")
        let store = GroupWakeStoreFake(initial: .init(roomID: roomID, highWatermark: 11))
        let relay = V2GroupEventWakeRelay(
            store: store,
            publisher: FailingGroupWakePublisher(),
            now: { Date(timeIntervalSince1970: 0) }
        )

        #expect(try await relay.runOnce(limit: 1) == .init(claimed: 1, published: 0, retryScheduled: 1))
        #expect(await store.pendingWake() == .init(roomID: roomID, highWatermark: 11))
    }

    @Test("foreground dispatcher coalesces a room watermark before optional publication")
    func foregroundDispatcherCoalescesWithoutDurableWork() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000d03")
        let publisher = ForegroundHintPublisherFake()
        let dispatcher = V2ForegroundGroupEventHintDispatcher(publisher: publisher)

        // Enqueue before the runtime-owned worker begins to make the
        // coalescing contract deterministic; command handlers only await
        // these actor-local calls, never the publisher's I/O.
        await dispatcher.publishForegroundHint(.init(roomID: roomID, highWatermark: 7))
        await dispatcher.publishForegroundHint(.init(roomID: roomID, highWatermark: 9))
        let task = Task { await dispatcher.run() }

        #expect(await publisher.next() == .init(roomID: roomID, highWatermark: 9))
        await dispatcher.finish()
        await task.value
    }
}

private actor GroupWakeStoreFake: V2GroupEventWakeStore {
    private var wake: V2GroupEventWake?
    private var revision: UInt64 = 1
    private var lease: V2GroupEventWakeLease?

    init(initial: V2GroupEventWake) { wake = initial }

    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) throws -> [V2GroupEventWakeLease] {
        guard limit > 0, let wake, lease == nil else { return [] }
        let result = V2GroupEventWakeLease(wake: wake, revision: revision, claimToken: UUID(), attempt: 1)
        lease = result
        return [result]
    }

    func markPublished(_ lease: V2GroupEventWakeLease) {
        guard self.lease?.claimToken == lease.claimToken else { return }
        self.lease = nil
        if revision == lease.revision { wake = nil }
    }

    func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt _: Date) {
        guard self.lease?.claimToken == lease.claimToken else { return }
        self.lease = nil
    }

    func replace(with replacement: V2GroupEventWake) {
        wake = replacement
        revision += 1
        lease = nil
    }

    func pendingWake() -> V2GroupEventWake? { wake }
}

private actor AdvancingGroupWakePublisher: V2GroupEventWakePublishing {
    private let store: GroupWakeStoreFake
    private let replacement: V2GroupEventWake
    private var published: [V2GroupEventWake] = []

    init(store: GroupWakeStoreFake, replacement: V2GroupEventWake) {
        self.store = store
        self.replacement = replacement
    }

    func publish(_ wake: V2GroupEventWake) async {
        published.append(wake)
        await store.replace(with: replacement)
    }

    func values() -> [V2GroupEventWake] { published }
}

private struct FailingGroupWakePublisher: V2GroupEventWakePublishing {
    func publish(_: V2GroupEventWake) async throws { throw GroupWakePublisherError.unavailable }
}

private actor ForegroundHintPublisherFake: V2ForegroundGroupEventHintPublishing {
    private var values: [V2GroupEventWake] = []
    private var continuation: CheckedContinuation<V2GroupEventWake, Never>?

    func publishForegroundHint(_ hint: V2GroupEventWake) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: hint)
        } else {
            values.append(hint)
        }
    }

    func next() async -> V2GroupEventWake {
        if !values.isEmpty { return values.removeFirst() }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private enum GroupWakePublisherError: Error { case unavailable }
