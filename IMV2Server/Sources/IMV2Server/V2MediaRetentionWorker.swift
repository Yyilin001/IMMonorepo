import Foundation

/// Schedules provider-byte cleanup without putting object locations or bearer
/// credentials into the chat database. The provider adapter consumes the
/// resulting outbox separately and can retry independently of chat writes.
public protocol V2MediaRetentionStore: Sendable {
    func expireEligibleMedia(now: Date, withdrawnRetention: TimeInterval, limit: Int) async throws -> Int
}

public struct V2MediaRetentionWorker: Sendable {
    private let store: any V2MediaRetentionStore
    private let now: @Sendable () -> Date
    private let withdrawnRetention: TimeInterval

    public init(
        store: any V2MediaRetentionStore,
        withdrawnRetention: TimeInterval = 30 * 86_400,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard withdrawnRetention > 0 else { throw V2MediaRetentionWorkerError.invalidRetention }
        self.store = store
        self.withdrawnRetention = withdrawnRetention
        self.now = now
    }

    /// Each call is bounded so it can run as a periodic, retryable worker.
    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        guard limit > 0 else { throw V2MediaRetentionWorkerError.invalidLimit }
        return try await store.expireEligibleMedia(now: now(), withdrawnRetention: withdrawnRetention, limit: limit)
    }
}

public enum V2MediaRetentionWorkerError: Error, Equatable, Sendable {
    case invalidRetention
    case invalidLimit
}
