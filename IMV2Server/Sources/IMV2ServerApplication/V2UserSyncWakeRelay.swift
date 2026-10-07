import Foundation
import IMV2ServerContracts

/// Relays committed target-user watermarks. An incomplete Gateway acceptance
/// retains the outbox revision for retry; client cursors remain authoritative.
public struct V2UserSyncWakeRelayReport: Equatable, Sendable {
    public let claimed: Int
    public let published: Int
    public let retryScheduled: Int

    public init(claimed: Int, published: Int, retryScheduled: Int) {
        self.claimed = claimed
        self.published = published
        self.retryScheduled = retryScheduled
    }
}


public struct V2UserSyncWakeRelay: Sendable {
    private let store: any V2UserSyncWakeStore
    private let publisher: any V2UserSyncWakePublishing
    private let now: @Sendable () -> Date

    public init(store: any V2UserSyncWakeStore, publisher: any V2UserSyncWakePublishing,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.publisher = publisher; self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2UserSyncWakeRelayReport {
        let leases = try await store.claimPending(now: now(), leaseDuration: 15, limit: limit)
        var published = 0
        var retried = 0
        for lease in leases {
            do {
                try Task.checkCancellation()
                try await publisher.publish(lease.wake)
                try await store.markPublished(lease)
                published += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard lease.attempt > 0,
                      let retryAt = v2PostgresFutureTimestamp(
                        now: now(), interval: v2RealtimePublicationRetryDelay(error: error,
                            identity: lease.wake.userID, attempt: lease.attempt, maximumDelay: 30)) else {
                    throw V2RealtimeDirectoryError.corruptPersistenceState
                }
                try await store.scheduleRetry(lease, nextAttemptAt: retryAt)
                retried += 1
            }
        }
        return .init(claimed: leases.count, published: published, retryScheduled: retried)
    }
}
