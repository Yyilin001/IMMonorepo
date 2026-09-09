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
    public let attempt: Int

    public init(mediaID: MediaID, reason: V2MediaPurgeReason, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.mediaID = mediaID
        self.reason = reason
        self.claimToken = claimToken
        self.attempt = attempt
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
    func scheduleRetry(_ lease: V2MediaPurgeLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

public struct V2MediaPurgeReport: Equatable, Sendable {
    public let claimedCount: Int
    public let completedCount: Int
    public let releasedCount: Int
    public let pausedCount: Int

    public init(claimedCount: Int, completedCount: Int, releasedCount: Int, pausedCount: Int = 0) {
        self.claimedCount = claimedCount
        self.completedCount = completedCount
        self.releasedCount = releasedCount
        self.pausedCount = pausedCount
    }
}

/// Bounded at-least-once cleanup. A provider error leaves only this cleanup
/// outbox item retryable; it cannot resurrect the terminal chat media state.
public struct V2MediaPurgeWorker: Sendable {
    private let store: any V2MediaPurgeStore
    private let provider: any V2MediaPurgeProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    public init(store: any V2MediaPurgeStore, provider: any V2MediaPurgeProvider, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, maximumConcurrency: Int = 4, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaPurgeWorkerError.invalidLeaseDuration }
        guard maximumConcurrency > 0 else { throw V2MediaPurgeWorkerError.invalidMaximumConcurrency }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2MediaPurgeReport {
        guard limit > 0 else { throw V2MediaPurgeWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var outcomes: [V2MediaPurgeWorkOutcome] = []
        for start in stride(from: 0, to: leases.count, by: maximumConcurrency) {
            let end = Swift.min(start + maximumConcurrency, leases.count)
            let batch = Array(leases[start..<end])
            let batchOutcomes = try await withThrowingTaskGroup(
                of: V2MediaPurgeWorkOutcome.self,
                returning: [V2MediaPurgeWorkOutcome].self
            ) { group in
                for lease in batch {
                    group.addTask {
                        do {
                            try await self.provider.purge(mediaID: lease.mediaID)
                            try await self.store.markCompleted(lease, now: self.now())
                            return .completed
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let failureTime = self.now()
                            let disposition = self.retryPolicy.disposition(
                                attempt: lease.attempt,
                                claimToken: lease.claimToken,
                                now: failureTime
                            )
                            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failureTime, retryAt) {
                                throw V2RoomWriteStoreError.corruptPersistenceState
                            }
                            try await self.store.scheduleRetry(lease, disposition: disposition, now: failureTime)
                            return disposition.isPause ? .paused : .released
                        }
                    }
                }
                var values: [V2MediaPurgeWorkOutcome] = []
                for try await value in group { values.append(value) }
                return values
            }
            outcomes.append(contentsOf: batchOutcomes)
        }
        return .init(
            claimedCount: leases.count,
            completedCount: outcomes.count(where: { $0 == .completed }),
            releasedCount: outcomes.count(where: { $0 == .released }),
            pausedCount: outcomes.count(where: { $0 == .paused })
        )
    }
}

public enum V2MediaPurgeWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
    case invalidMaximumConcurrency
}

private enum V2MediaPurgeWorkOutcome: Equatable, Sendable { case completed, released, paused }

private extension V2DurableRetryDisposition {
    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }
}
