import Foundation

/// Runtime-owned continuation of bounded room-log passes. Wakes coalesce,
/// including a wake received before the loop starts or during a page commit.
/// Every reconnect resumes durable cursors; no UI or availability hint is
/// required between pages of an already discovered backlog.
public actor V2RoomLogCatchUpWorker {
    private let engine: V2GroupEventSyncEngine
    private let maximumPagesPerRound: Int
    private let onProgress: @Sendable (V2GroupEventBackgroundSyncProgress) async -> Void
    private var requested = false
    private var runID: UUID?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?

    public init(
        engine: V2GroupEventSyncEngine,
        maximumPagesPerRound: Int = 12,
        onProgress: @escaping @Sendable (V2GroupEventBackgroundSyncProgress) async -> Void = { _ in }
    ) {
        precondition(maximumPagesPerRound > 0 && maximumPagesPerRound <= 10_000)
        self.engine = engine
        self.maximumPagesPerRound = maximumPagesPerRound
        self.onProgress = onProgress
    }

    public func requestCatchUp() {
        requested = true
        waiter?.continuation.resume()
        waiter = nil
    }

    public func run() async throws {
        let id = UUID()
        runID = id
        // A replacement runtime always rechecks its durable directory. Its
        // old cancelled pass is drained by the engine's serialized pass owner.
        requestCatchUp()
        defer { if runID == id { runID = nil } }
        while true {
            try Task.checkCancellation()
            guard runID == id else { throw CancellationError() }
            if !requested { await waitForRequest() }
            try Task.checkCancellation()
            guard runID == id else { throw CancellationError() }
            requested = false
            var remaining = false
            repeat {
                try Task.checkCancellation()
                guard runID == id else { throw CancellationError() }
                let progress: V2GroupEventBackgroundSyncProgress
                do {
                    progress = try await engine.synchronizeBackgroundKnownRooms(maximumPages: maximumPagesPerRound)
                } catch V2ClientSyncError.resetPending {
                    // Snapshot activation temporarily fences projections.
                    // The personal-sync completion requests the next pass;
                    // keep its connection and staged reset alive meanwhile.
                    break
                }
                try Task.checkCancellation()
                guard runID == id else { throw CancellationError() }
                await onProgress(progress)
                remaining = progress.mayHaveRemainingWork
                await Task.yield()
            } while remaining
        }
    }

    private func waitForRequest() async {
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if requested || Task.isCancelled { continuation.resume() }
                else { waiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        waiter?.continuation.resume()
        waiter = nil
    }
}
