import Foundation
import IMV2Core

public struct V2ForwardMediaImportLease: Sendable {
    public let export: V2ForwardExport
    public let ordinal: Int
    public let targetMediaID: MediaID
    public let targetUploadSessionID: UUID
    public let copiedDigest: Data?
    public let claimToken: UUID
    public let attempt: Int
    public let expiresAt: Date
    public var source: V2ForwardExportMedia { export.intent.media[ordinal] }
}

public struct V2ForwardMediaCopyReceipt: Equatable, Sendable {
    public let byteCount: Int64
    public let digest: Data
    public init(byteCount: Int64, digest: Data) throws {
        guard byteCount > 0, digest.count == 32 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.byteCount = byteCount; self.digest = digest
    }
}

/// Provider-owned byte I/O, outside all database transactions. Installation
/// must never overwrite a different object. A retry verifies the existing
/// object against the persisted copiedDigest, or reconstructs those same bytes.
public protocol V2ForwardMediaObjectCopying: Sendable {
    func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt
}

public enum V2ForwardMediaCopyError: Error, Equatable, Sendable {
    case invalidReceipt
    case byteCountMismatch
    case contentConflict
    case sizeLimitExceeded
    case sourceUnavailable
}

public enum V2ForwardMediaImportOutcome: Equatable, Sendable {
    case idle
    case ready
    case rejected
    case retryScheduled
    case paused
    case superseded
}

/// One bounded attachment per call. The surrounding export delivery worker
/// chooses concurrency across exports; this worker never nests another pool.
public struct V2ForwardMediaImportWorker: Sendable {
    private let store: PostgresV2ForwardMediaImportStore
    private let copier: any V2ForwardMediaObjectCopying
    private let scanner: any V2MediaScanProvider
    private let leaseDuration: TimeInterval
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(store: PostgresV2ForwardMediaImportStore, copier: any V2ForwardMediaObjectCopying,
                scanner: any V2MediaScanProvider, leaseDuration: TimeInterval = 300,
                retryPolicy: V2DurableRetryPolicy = .standard,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= 3_600 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.store = store; self.copier = copier; self.scanner = scanner
        self.leaseDuration = leaseDuration; self.retryPolicy = retryPolicy; self.now = now
    }

    public func runOnce(exportID: UUID) async throws -> V2ForwardMediaImportOutcome {
        guard let lease = try await store.claim(exportID: exportID, now: now(), leaseDuration: leaseDuration) else {
            // A previous process may have paused and lost its response. Report
            // durable state so source delivery cannot poll it forever as idle.
            return try await store.hasPausedImport(exportID: exportID) ? .paused : .idle
        }
        do {
            try Task.checkCancellation()
            let copied = try await copier.copy(lease)
            guard copied.byteCount == lease.source.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
            guard try await store.recordCopied(lease, receipt: copied, now: now()) else { return .superseded }
            try Task.checkCancellation()
            let result = try await scanner.scan(mediaID: lease.targetMediaID)
            try Task.checkCancellation()
            guard try await store.complete(lease, receipt: copied, result: result, now: now()) else { return .superseded }
            return result == .passed ? .ready : .rejected
        } catch is CancellationError {
            // Do not purge: a newer lease may already have installed or used
            // the same stable target object. Cancellation releases only ours.
            _ = try? await store.retry(lease, disposition: .retry(at: now()), now: now())
            throw CancellationError()
        } catch V2ForwardMediaCopyError.contentConflict {
            return try await reject(lease)
        } catch V2ForwardMediaCopyError.byteCountMismatch {
            return try await reject(lease)
        } catch V2ForwardMediaCopyError.sizeLimitExceeded {
            return try await reject(lease)
        } catch {
            let failedAt = now()
            let disposition = retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: failedAt)
            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(failedAt, retryAt) {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            guard try await store.retry(lease, disposition: disposition, now: failedAt) else { return .superseded }
            switch disposition {
            case .pause: return .paused
            case .retry: return .retryScheduled
            }
        }
    }

    private func reject(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaImportOutcome {
        try await store.reject(lease, now: now()) ? .rejected : .superseded
    }
}
