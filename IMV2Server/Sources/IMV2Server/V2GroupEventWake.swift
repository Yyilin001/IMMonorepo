import Foundation
import IMV2Core

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
}

public struct V2NoopForegroundGroupEventHintPublisher: V2ForegroundGroupEventHintPublishing {
    public init() {}
    public func publishForegroundHint(_: V2GroupEventWake) async {}
}

/// Runtime-owned mailbox for foreground hints. It coalesces watermarks per
/// room and deliberately returns from `publishForegroundHint` before broker
/// I/O begins, keeping a sender's acceptance response independent from an
/// optional NATS connection or a slow local socket write.
public actor V2ForegroundGroupEventHintDispatcher: V2ForegroundGroupEventHintPublishing {
    private let publisher: any V2ForegroundGroupEventHintPublishing
    private let maximumPendingRooms: Int
    private let signal: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var pending: [RoomID: V2GroupEventWake] = [:]

    public init(
        publisher: any V2ForegroundGroupEventHintPublishing,
        maximumPendingRooms: Int = 256
    ) {
        precondition(maximumPendingRooms > 0)
        self.publisher = publisher
        self.maximumPendingRooms = maximumPendingRooms
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = stream.stream
        signalContinuation = stream.continuation
    }

    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        if let existing = pending[hint.roomID], existing.highWatermark >= hint.highWatermark {
            return
        }
        if pending[hint.roomID] == nil,
           pending.count >= maximumPendingRooms,
           let bufferedRoom = pending.keys.first {
            // Hints are deliberately lossy and durable cursor pulls are the
            // recovery path. Bound memory under a many-room burst by keeping
            // the newest work instead of growing with traffic history.
            pending.removeValue(forKey: bufferedRoom)
        }
        pending[hint.roomID] = hint
        signalContinuation.yield()
    }

    /// Called by one task whose lifetime is owned by the gateway runtime.
    /// No durable state depends on this loop, so shutdown may discard pending
    /// hints safely; the cursor/personal-sync recovery paths repair visibility.
    public func run() async {
        for await _ in signal {
            if Task.isCancelled { return }
            let batch = pending.values
            pending.removeAll(keepingCapacity: true)
            for hint in batch {
                if Task.isCancelled { return }
                await publisher.publishForegroundHint(hint)
            }
        }
    }

    public func finish() {
        pending.removeAll(keepingCapacity: false)
        signalContinuation.finish()
    }

    func pendingRoomCount() -> Int { pending.count }
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
public struct V2LocalGroupEventWakePublisher: V2GroupEventWakePublishing, V2ForegroundGroupEventHintPublishing {
    private let registry: V2DeviceConnectionRegistry

    public init(registry: V2DeviceConnectionRegistry) { self.registry = registry }

    public func publish(_ wake: V2GroupEventWake) async throws {
        await registry.notifyForegroundGroupAvailable(roomID: wake.roomID, highWatermark: wake.highWatermark)
    }

    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        await registry.notifyForegroundGroupAvailable(roomID: hint.roomID, highWatermark: hint.highWatermark)
    }
}
