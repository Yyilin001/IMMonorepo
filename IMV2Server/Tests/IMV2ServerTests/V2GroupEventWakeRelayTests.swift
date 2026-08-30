import Foundation
import IMV2Core
import Synchronization
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
        // coalescing contract deterministic; command handlers perform only a
        // bounded process-local submit and never await the publisher's I/O.
        await dispatcher.publishForegroundHint(.init(roomID: roomID, highWatermark: 7))
        await dispatcher.publishForegroundHint(.init(roomID: roomID, highWatermark: 9))
        let task = Task { await dispatcher.run() }

        #expect(await publisher.next() == .init(roomID: roomID, highWatermark: 9))
        dispatcher.finish()
        await task.value
    }

    @Test("foreground dispatcher bounds distinct rooms while publication is stalled")
    func foregroundDispatcherBoundsDistinctRooms() async throws {
        let dispatcher = V2ForegroundGroupEventHintDispatcher(
            publisher: ForegroundHintPublisherFake(), maximumPendingRooms: 2
        )
        for suffix in 4...6 {
            let roomID = try RoomID(
                String(format: "00000000-0000-0000-0000-%012x", suffix)
            )
            await dispatcher.publishForegroundHint(
                .init(roomID: roomID, highWatermark: UInt64(suffix))
            )
        }

        #expect(dispatcher.pendingRoomCount() == 2)
        dispatcher.finish()
    }

    @Test("foreground dispatcher uses a bounded immediate local direct-event publication")
    func foregroundDispatcherUsesImmediateDirectEventPublisher() async throws {
        let publisher = ImmediateForegroundHintPublisherFake()
        let dispatcher = V2ForegroundGroupEventHintDispatcher(publisher: publisher)
        let message = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000d10"),
            roomID: try .init("00000000-0000-0000-0000-000000000d11"),
            roomSequence: 12,
            senderUserID: try .init("00000000-0000-0000-0000-000000000d12"),
            clientMessageID: try .init("00000000-0000-0000-0000-000000000d13"),
            text: "hello",
            mediaPresentations: [],
            usesRoomEventLog: true,
            sourceEventID: try .init("00000000-0000-0000-0000-000000000d14"),
            acceptedMembershipRevision: 1,
            directRecipientUserID: try .init("00000000-0000-0000-0000-000000000d15"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        dispatcher.submitForegroundDirectMessage(message)
        #expect(publisher.immediateCount == 1)
        #expect(dispatcher.pendingRoomCount() == 0)
        let task = Task { await dispatcher.run() }
        #expect(publisher.asynchronousCount == 0)
        dispatcher.finish()
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

private final class ImmediateForegroundHintPublisherFake:
    V2ForegroundGroupEventHintPublishing,
    V2ImmediateForegroundDirectEventPublishing,
    Sendable
{
    private struct State: Sendable {
        var immediateCount = 0
        var asynchronousCount = 0
    }

    private let state = Mutex(State())

    var immediateCount: Int { state.withLock(\.immediateCount) }
    var asynchronousCount: Int { state.withLock(\.asynchronousCount) }

    func publishForegroundHint(_: V2GroupEventWake) async {
        state.withLock { $0.asynchronousCount += 1 }
    }

    func publishForegroundDirectEventImmediately(_: V2DirectRoomLiveEvent) -> Bool {
        state.withLock { $0.immediateCount += 1 }
        return true
    }
}

private enum GroupWakePublisherError: Error { case unavailable }
