import Foundation
import IMV2Core
import Synchronization

/// Metadata-only work emitted after a Hybrid room event is committed. The
/// payload deliberately excludes event content and recipient identity.
public struct V2GroupEventWake: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

public struct V2GroupEventWakeLease: Equatable, Sendable {
    public let wake: V2GroupEventWake
    public let revision: UInt64
    public let claimToken: UUID
    public let attempt: Int

    public init(wake: V2GroupEventWake, revision: UInt64, claimToken: UUID, attempt: Int) {
        self.wake = wake
        self.revision = revision
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

public protocol V2GroupEventWakeStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2GroupEventWakeLease]
    /// A newer event can replace the claimed revision while publication is in
    /// flight. The store must preserve that newer waterline rather than delete
    /// the coalesced row.
    func markPublished(_ lease: V2GroupEventWakeLease) async throws
    func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt: Date) async throws
}

public protocol V2GroupEventWakePublishing: Sendable {
    func publish(_ wake: V2GroupEventWake) async throws
}

/// Best-effort hint emitted after a group message source transaction commits.
/// Unlike `V2GroupEventWakePublishing`, this contract has no outbox, retry,
/// or delivery obligation. Its only purpose is to shorten the time before an
/// already-open detail view pulls the authorized room log.
public protocol V2ForegroundGroupEventHintPublishing: Sendable {
    func publishForegroundHint(_ hint: V2GroupEventWake) async
    func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async
    func publishForegroundDirectMessage(_ message: V2AcceptedMessage) async
}

/// Optional process-local acceleration for publishers that can complete a
/// foreground direct-event publication without suspension.  A conformer must
/// perform only bounded in-memory routing and enqueue work; broker I/O and
/// actor hops remain on ``V2ForegroundGroupEventHintPublishing``.
///
/// Returning `false` asks the dispatcher to retain its ordinary asynchronous
/// publication path.  This keeps multi-gateway/NATS deployments and test
/// embeddings semantically identical while a local SwiftNIO gateway avoids a
/// short-lived child task for every accepted private message.
protocol V2ImmediateForegroundDirectEventPublishing: Sendable {
    func publishForegroundDirectEventImmediately(_ event: V2DirectRoomLiveEvent) -> Bool
}

/// Non-suspending post-commit boundary used by the Gateway acceptance path.
/// Implementations must only perform bounded process-local enqueue work. Any
/// broker, socket, serialization, or retry work belongs to a runtime-owned
/// consumer behind this boundary.
public protocol V2ForegroundGroupEventHintSubmitting: Sendable {
    func submitForegroundHint(_ hint: V2GroupEventWake)
    func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent)
    func submitForegroundDirectMessage(_ message: V2AcceptedMessage)
    func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    )
}

extension V2ForegroundGroupEventHintSubmitting {
    public func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) {
        // Compatibility publishers retain the safe metadata-only wake. The
        // concrete Gateway dispatcher overrides this method to preserve the
        // already-authorized live payload and exact socket exclusion.
        submitForegroundHint(.init(
            roomID: event.roomID,
            highWatermark: event.highWatermark
        ))
    }

    public func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID _: UUID?
    ) {
        submitForegroundDirectMessage(message)
    }
}

extension V2ForegroundGroupEventHintPublishing {
    /// Compatibility fallback for publishers that have not yet been upgraded
    /// to carry a live payload across a process boundary.  Correctness stays
    /// with the metadata wake and durable cursor pull.
    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        await publishForegroundHint(.init(roomID: event.roomID, highWatermark: event.highWatermark))
    }

    public func publishForegroundDirectMessage(_ message: V2AcceptedMessage) async {
        guard let event = V2DirectRoomLiveEvent(message) else { return }
        await publishForegroundDirectEvent(event)
    }
}

/// Runtime-owned mailbox for foreground hints. It coalesces watermarks per
/// room and deliberately returns from `publishForegroundHint` before broker
/// I/O begins, keeping a sender's acceptance response independent from an
/// optional NATS connection or a slow local socket write.
public final class V2ForegroundGroupEventHintDispatcher:
    V2ForegroundGroupEventHintPublishing,
    V2ForegroundGroupEventHintSubmitting,
    Sendable
{
    private let publisher: any V2ForegroundGroupEventHintPublishing
    private let immediateDirectEventPublisher: (any V2ImmediateForegroundDirectEventPublishing)?
    private let maximumPendingRooms: Int
    /// Live foreground sends are lossy accelerators, but a single serial
    /// publisher must not become the throughput ceiling for unrelated rooms.
    /// A modest bound protects the gateway executor and socket buffers while
    /// retaining a batch boundary between successive mailbox drains.
    private let maximumConcurrentPublications: Int
    private let signal: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private struct Pending: Sendable {
        let wake: V2GroupEventWake
        let directEvent: V2DirectRoomLiveEvent?
    }

    private struct Publication: Sendable {
        let wake: V2GroupEventWake
        let directEvent: V2DirectRoomLiveEvent?
    }

    private struct State: Sendable {
        var pending: [RoomID: Pending] = [:]
        var finished = false
    }
    private let state = Mutex(State())

    public init(
        publisher: any V2ForegroundGroupEventHintPublishing,
        maximumPendingRooms: Int = 256,
        maximumConcurrentPublications: Int = 8
    ) {
        precondition(maximumPendingRooms > 0 && maximumConcurrentPublications > 0)
        self.publisher = publisher
        immediateDirectEventPublisher = publisher as? any V2ImmediateForegroundDirectEventPublishing
        self.maximumPendingRooms = maximumPendingRooms
        self.maximumConcurrentPublications = maximumConcurrentPublications
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = stream.stream
        signalContinuation = stream.continuation
    }

    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        submitForegroundHint(hint)
    }

    public func publishForegroundDirectMessage(_ message: V2AcceptedMessage) async {
        submitForegroundDirectMessage(message)
    }

    public func submitForegroundHint(_ hint: V2GroupEventWake) {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            if let existing = state.pending[hint.roomID],
               existing.wake.highWatermark >= hint.highWatermark {
                return false
            }
            if state.pending[hint.roomID] == nil,
               state.pending.count >= maximumPendingRooms,
               let bufferedRoom = state.pending.keys.first {
                // Hints are deliberately lossy and durable cursor pulls are
                // the recovery path. Keep the newest bounded room set.
                state.pending.removeValue(forKey: bufferedRoom)
            }
            state.pending[hint.roomID] = .init(wake: hint, directEvent: nil)
            return true
        }
        if accepted { signalContinuation.yield() }
    }

    public func submitForegroundDirectMessage(_ message: V2AcceptedMessage) {
        submitForegroundDirectMessage(message, excludingConnectionID: nil)
    }

    public func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    ) {
        guard let event = V2DirectRoomLiveEventDraft(
            message,
            excludingConnectionID: excludingConnectionID
        )?.materialized() else { return }
        submitForegroundDirectEvent(event)
    }

    public func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) {
        // The production single-Gateway publisher performs only immutable
        // frame preparation and bounded per-connection mailbox appends. Do it
        // before touching the shared fallback mailbox, avoiding one global
        // lock, AsyncStream signal and executor hop for every accepted DM.
        if immediateDirectEventPublisher?.publishForegroundDirectEventImmediately(event) == true {
            return
        }
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            if let existing = state.pending[event.roomID],
               existing.wake.highWatermark >= event.roomSequence {
                return false
            }
            if state.pending[event.roomID] == nil,
               state.pending.count >= maximumPendingRooms,
               let bufferedRoom = state.pending.keys.first {
                state.pending.removeValue(forKey: bufferedRoom)
            }
            state.pending[event.roomID] = .init(
                wake: .init(
                    roomID: event.roomID,
                    highWatermark: event.roomSequence
                ),
                directEvent: event
            )
            return true
        }
        if accepted { signalContinuation.yield() }
    }

    /// Called by one task whose lifetime is owned by the gateway runtime.
    /// No durable state depends on this loop, so shutdown may discard pending
    /// hints safely; the cursor/personal-sync recovery paths repair visibility.
    public func run() async {
        for await _ in signal {
            if Task.isCancelled { return }
            let batch = state.withLock { state in
                let batch = Array(state.pending.values)
                state.pending.removeAll(keepingCapacity: true)
                return batch
            }

            // A later room event is only placed in a subsequent drain after
            // this one has completed. Within a drain, rooms are independent:
            // clients still require exact cursor continuity and fall back to
            // the durable log for a duplicate, a gap, or a dropped hint.
            var lowerBound = 0
            while lowerBound < batch.count {
                if Task.isCancelled { return }
                let upperBound = min(
                    lowerBound + maximumConcurrentPublications, batch.count
                )
                let slice = batch[lowerBound..<upperBound]
                let publicationSink = publisher
                let immediateSink = immediateDirectEventPublisher
                var fallbacks: [Publication] = []
                fallbacks.reserveCapacity(slice.count)
                for item in slice {
                    let event = item.directEvent
                    if let event,
                       immediateSink?.publishForegroundDirectEventImmediately(event) == true {
                        continue
                    }
                    fallbacks.append(.init(wake: item.wake, directEvent: event))
                }
                guard !fallbacks.isEmpty else {
                    lowerBound = upperBound
                    continue
                }
                await withTaskGroup(of: Void.self) { group in
                    for publication in fallbacks {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            if let event = publication.directEvent {
                                await publicationSink.publishForegroundDirectEvent(event)
                            } else {
                                await publicationSink.publishForegroundHint(publication.wake)
                            }
                        }
                    }
                }
                lowerBound = upperBound
            }
        }
    }

    public func finish() {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish { signalContinuation.finish() }
    }

    func pendingRoomCount() -> Int { state.withLock { $0.pending.count } }
}

public struct V2GroupEventWakeRelayReport: Equatable, Sendable {
    public let claimed: Int
    public let published: Int
    public let retryScheduled: Int

    public init(claimed: Int, published: Int, retryScheduled: Int) {
        self.claimed = claimed
        self.published = published
        self.retryScheduled = retryScheduled
    }
}

/// Bounded bridge from the durable coalescing table to a non-authoritative
/// routing mechanism. A publish failure never rolls back room events or
/// fan-out; it only delays foreground visibility until a retry or cursor pull.
public struct V2GroupEventWakeRelay: Sendable {
    private let store: any V2GroupEventWakeStore
    private let publisher: any V2GroupEventWakePublishing
    private let leaseDuration: TimeInterval
    private let retryMaximumDelay: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupEventWakeStore,
        publisher: any V2GroupEventWakePublishing,
        leaseDuration: TimeInterval = 15,
        retryMaximumDelay: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0 && retryMaximumDelay > 0)
        self.store = store
        self.publisher = publisher
        self.leaseDuration = leaseDuration
        self.retryMaximumDelay = retryMaximumDelay
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2GroupEventWakeRelayReport {
        precondition(limit > 0)
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var published = 0
        var retryScheduled = 0
        for lease in leases {
            do {
                try Task.checkCancellation()
                try await publisher.publish(lease.wake)
                try await store.markPublished(lease)
                published += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let exponent = min(max(lease.attempt - 1, 0), 5)
                let delay = min(retryMaximumDelay, pow(2, Double(exponent)))
                try await store.scheduleRetry(lease, nextAttemptAt: now().addingTimeInterval(delay))
                retryScheduled += 1
            }
        }
        return .init(claimed: leases.count, published: published, retryScheduled: retryScheduled)
    }
}

/// A single-node development deployment can route directly to its local
/// registry. Multi-gateway deployments replace this publisher with the NATS
/// adapter; both preserve the same metadata-only wake contract.
public struct V2LocalGroupEventWakePublisher:
    V2GroupEventWakePublishing,
    V2ForegroundGroupEventHintPublishing,
    V2ImmediateForegroundDirectEventPublishing
{
    private let registry: V2DeviceConnectionRegistry

    public init(registry: V2DeviceConnectionRegistry) { self.registry = registry }

    public func publish(_ wake: V2GroupEventWake) async throws {
        await registry.notifyForegroundGroupAvailable(roomID: wake.roomID, highWatermark: wake.highWatermark)
    }

    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        await registry.notifyForegroundGroupAvailable(roomID: hint.roomID, highWatermark: hint.highWatermark)
    }

    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        await registry.notifyForegroundDirectEvent(event)
    }

    func publishForegroundDirectEventImmediately(_ event: V2DirectRoomLiveEvent) -> Bool {
        registry.submitForegroundDirectEvent(event)
    }

    public func publishForegroundDirectMessage(_ message: V2AcceptedMessage) async {
        guard let event = V2DirectRoomLiveEvent(message) else { return }
        await publishForegroundDirectEvent(event)
    }
}
