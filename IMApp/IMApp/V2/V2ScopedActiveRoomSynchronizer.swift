import Foundation
import IMV2ClientKit
import IMV2Core

/// One detail-view task owns this adapter and its lease. Cancelling a grace
/// wait cancels only that waiter, while the snapshot pump keeps the lease live.
actor V2ScopedActiveRoomSynchronizer: V2ActiveHybridGroupSynchronizing {
    nonisolated let usesRuntimeRecoveryClock = true
    private let roomID: RoomID
    private let owner: V2RoomSubscriptionCoordinator
    private let base: any V2ActiveHybridGroupSynchronizing
    private var lease: V2RoomSubscriptionLease?
    private var pump: Task<Void, Never>?
    private var closed = false
    private var generation: UUID?
    private var recoveryID: UUID?
    private var lastWake: V2GroupEventAvailabilityHint?
    private var revoked = false
    private var pending: V2ActiveHybridGroupWake?
    private var waiter: (id: UUID, continuation: CheckedContinuation<V2ActiveHybridGroupWake, Error>)?

    init(roomID: RoomID, owner: V2RoomSubscriptionCoordinator, base: any V2ActiveHybridGroupSynchronizing) {
        self.roomID = roomID
        self.owner = owner
        self.base = base
    }

    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome {
        try Task.checkCancellation()
        guard !closed, roomID == self.roomID.rawValue else { throw CancellationError() }
        if lease == nil {
            let acquired = try await owner.acquire(roomID: self.roomID, channels: [.roomEvents])
            guard !Task.isCancelled, !closed else {
                await owner.release(roomID: self.roomID, consumerID: acquired.id)
                throw CancellationError()
            }
            lease = acquired
            pump = Task { [weak self] in
                for await snapshot in acquired.updates {
                    guard !Task.isCancelled else { break }
                    await self?.consume(snapshot)
                }
                await self?.finishWait()
            }
        }
        // The desired subscription exists even when offline. Its first active
        // snapshot schedules a durable pull from the authoritative cursor.
        return .subscribed(highWatermark: 0)
    }

    func synchronizeOnePage(roomID: String) async throws -> V2ActiveHybridGroupSyncOutcome {
        guard !closed, roomID == self.roomID.rawValue else { throw CancellationError() }
        guard !revoked else { return .synchronized(appliedEventCount: 0, hasMore: false) }
        let result = try await base.synchronizeOnePage(roomID: roomID)
        // A local membership gap must not discard a still-open scene's intent.
        // The owner suppresses unauthorized wire subscriptions and wakes us
        // again after authoritative membership recovery.
        if case .notHybridRoom = result { return .synchronized(appliedEventCount: 0, hasMore: false) }
        return result
    }

    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) async throws -> Bool {
        guard !closed, !revoked, generation != nil, generation == wake.connectionID else { return false }
        return try await base.applyLiveEvent(wake)
    }

    func nextWake() async throws -> V2ActiveHybridGroupWake {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let pending { self.pending = nil; return pending }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !closed else { continuation.resume(throwing: CancellationError()); return }
                guard waiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                waiter = (id, continuation)
            }
        }, onCancel: { Task { await self.cancelWait(id) } })
    }

    func unsubscribe(roomID: String) async { await close() }

    func close() async {
        guard !closed else { return }
        closed = true
        pending = nil
        finishWait()
        let currentPump = pump
        pump = nil
        currentPump?.cancel()
        if let lease {
            self.lease = nil
            await owner.release(roomID: roomID, consumerID: lease.id)
        }
        await currentPump?.value
    }

    private func consume(_ snapshot: V2RoomSubscriptionSnapshot) {
        guard !closed else { return }
        let connectionChanged = generation != snapshot.connectionID
        if connectionChanged {
            generation = snapshot.connectionID
            pending = nil
            recoveryID = nil
            lastWake = nil
        }
        revoked = snapshot.state == .revoked
        guard snapshot.state == .subscribed || revoked else { return }
        let recoveryChanged = recoveryID != snapshot.recoveryID
        guard connectionChanged || recoveryChanged || lastWake != snapshot.wake || revoked else { return }
        recoveryID = snapshot.recoveryID
        lastWake = snapshot.wake
        // Periodic recovery must still pull even when the last acceleration
        // payload was already applied. A fresh payload within the existing
        // 100 ms grace can satisfy the required high watermark normally.
        let wake = V2ActiveHybridGroupWake(
            roomID: roomID.rawValue,
            highWatermark: snapshot.wake?.highWatermark ?? 0,
            liveEvents: recoveryChanged ? [] : snapshot.wake?.liveEvents ?? [],
            connectionID: snapshot.connectionID
        )
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: wake)
        } else { pending = wake }
    }

    private func finishWait() {
        waiter?.continuation.resume(throwing: CancellationError())
        waiter = nil
    }
    private func cancelWait(_ id: UUID) {
        guard waiter?.id == id else { return }
        finishWait()
    }
}
