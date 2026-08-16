import Foundation

/// Persistence capability for phase B of fan-out completion. Implementations
/// claim a bounded batch with skip-locked semantics and commit all capacity
/// releases atomically. Event, room and shard identities remain inside the
/// persistence boundary so metrics cannot acquire high-cardinality labels.
public protocol V2FanoutCompletionReleaseStore: Sendable {
    func releaseTerminalCompletionUnits(
        now: Date,
        limit: Int
    ) async throws -> V2FanoutCompletionReleaseReport
}

public struct V2FanoutCompletionReleaseReport: Equatable, Sendable {
    public let releasedCount: Int
    public let closedPlanCount: Int

    public init(releasedCount: Int, closedPlanCount: Int) {
        precondition(releasedCount >= 0 && closedPlanCount >= 0 && closedPlanCount <= releasedCount)
        self.releasedCount = releasedCount
        self.closedPlanCount = closedPlanCount
    }
}

/// Bounded recovery worker for terminal completion units. Polling is a
/// correctness path, not merely a wake hint, so a process crash between the
/// projection and release phases is repaired after restart.
public struct V2FanoutCompletionReleaseWorker: Sendable {
    private let store: any V2FanoutCompletionReleaseStore
    private let now: @Sendable () -> Date

    public init(
        store: any V2FanoutCompletionReleaseStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2FanoutCompletionReleaseReport {
        precondition(limit > 0)
        try Task.checkCancellation()
        return try await store.releaseTerminalCompletionUnits(now: now(), limit: limit)
    }
}
