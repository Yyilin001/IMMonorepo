import Foundation
import IMV2Core

public enum V2MediaScanResult: Equatable, Sendable {
    case passed
    case failed
}

public struct V2MediaScanLease: Equatable, Sendable {
    public let mediaID: MediaID
    public let claimToken: UUID
    public let attempt: Int

    public init(mediaID: MediaID, claimToken: UUID, attempt: Int = 1) {
        precondition(attempt > 0)
        self.mediaID = mediaID
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

/// The scanner resolves provider-private object identity behind this boundary;
/// the chat worker passes only an opaque media ID and never receives bytes,
/// filename, hash, thumbnail, object key, or provider credential.
public protocol V2MediaScanProvider: Sendable {
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult
}

public protocol V2MediaScanStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2MediaScanLease]
    func complete(_ lease: V2MediaScanLease, result: V2MediaScanResult, now: Date) async throws
    func scheduleRetry(_ lease: V2MediaScanLease, disposition: V2DurableRetryDisposition, now: Date) async throws
}

public struct V2MediaScanReport: Equatable, Sendable {
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

/// Bounded scanner worker. A provider failure cannot make media referenceable:
/// its outbox item is retried while the media object remains `scanning`.
public struct V2MediaScanWorker: Sendable {
    private let store: any V2MediaScanStore
    private let provider: any V2MediaScanProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let maximumConcurrency: Int
    private let now: @Sendable () -> Date

    public init(store: any V2MediaScanStore, provider: any V2MediaScanProvider, leaseDuration: TimeInterval = 30, retryPolicy: V2DurableRetryPolicy = .standard, maximumConcurrency: Int = 4, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration > 0 else { throw V2MediaScanWorkerError.invalidLeaseDuration }
        guard maximumConcurrency > 0 else { throw V2MediaScanWorkerError.invalidMaximumConcurrency }
        self.store = store
        self.provider = provider
        self.leaseDuration = leaseDuration
        self.retryPolicy = retryPolicy
        self.maximumConcurrency = maximumConcurrency
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2MediaScanReport {
        guard limit > 0 else { throw V2MediaScanWorkerError.invalidLimit }
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var outcomes: [V2MediaWorkOutcome] = []
        for start in stride(from: 0, to: leases.count, by: maximumConcurrency) {
            let end = Swift.min(start + maximumConcurrency, leases.count)
            let batch = Array(leases[start..<end])
            let batchOutcomes = try await withThrowingTaskGroup(
                of: V2MediaWorkOutcome.self,
                returning: [V2MediaWorkOutcome].self
            ) { group in
                for lease in batch {
                    group.addTask {
                        do {
                            let result = try await self.provider.scan(mediaID: lease.mediaID)
                            try await self.store.complete(lease, result: result, now: self.now())
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
                var values: [V2MediaWorkOutcome] = []
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

public enum V2MediaScanWorkerError: Error, Equatable, Sendable {
    case invalidLeaseDuration
    case invalidLimit
    case invalidMaximumConcurrency
}

private enum V2MediaWorkOutcome: Equatable, Sendable { case completed, released, paused }

private extension V2DurableRetryDisposition {
    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }
}
