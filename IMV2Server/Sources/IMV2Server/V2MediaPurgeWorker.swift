import Foundation
import IMV2Core

public enum V2MediaPurgeReason: String, Equatable, Sendable {
    case unreferencedExpired = "unreferenced_expired"
    case withdrawnRetentionElapsed = "withdrawn_retention_elapsed"
}

public struct V2MediaPurgeLease: Equatable, Sendable {
    public let mediaID: MediaID
    public let reason: V2MediaPurgeReason
    public let claimToken: UUID

    public init(mediaID: MediaID, reason: V2MediaPurgeReason, claimToken: UUID) {
        self.mediaID = mediaID
        self.reason = reason
        self.claimToken = claimToken
    }
}

/// The provider maps the opaque media ID to its private object location. The
/// chat worker never receives an object key, URL, or credential.
public protocol V2MediaPurgeProvider: Sendable {
    func purge(mediaID: MediaID) async throws
}

public protocol V2MediaPurgeStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaPurgeLease]
    func markCompleted(_ lease: V2MediaPurgeLease, now: Date) async throws
    func release(_ lease: V2MediaPurgeLease) async throws
}

public struct V2MediaPurgeReport: Equatable, Sendable {
    public let claimedCount: Int
    public let completedCount: Int
    public let releasedCount: Int

    public init(claimedCount: Int, completedCount: Int, releasedCount: Int) {
        self.claimedCount = claimedCount
        self.completedCount = completedCount
        self.releasedCount = releasedCount
    }
}

/// Bounded at-least-once cleanup. A provider error leaves only this cleanup
/// outbox item retryable; it cannot resurrect the terminal chat media state.
public struct V2MediaPurgeWorker: Sendable {
    private let store: any V2MediaPurgeStore
    private let provider: any V2MediaPurgeProvider
    private let leaseDuration: TimeInterval
    private let now: @Sendable () -> Date

    public init(store: any V2MediaPurgeStore, provider: any V2MediaPurgeProvider, leaseDuration: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaPurgeWorkerError.invalidLeaseDuration }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2MediaPurgeReport {
        guard limit > 0 else { throw V2MediaPurgeWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        var released = 0
        for lease in leases {
            do {
                try await provider.purge(mediaID: lease.mediaID)
                try await store.markCompleted(lease, now: now())
                completed += 1
            } catch {
                try await store.release(lease)
                released += 1
            }
        }
        return .init(claimedCount: leases.count, completedCount: completed, releasedCount: released)
    }
}

public enum V2MediaPurgeWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
}
