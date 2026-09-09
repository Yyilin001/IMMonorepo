import Foundation

/// A trusted owner boundary. nil means durable target work is still pending;
/// it never means rejected, completed, or safe to release the source pin.
public protocol V2ForwardExportDelivering: Sendable {
    // Implementations must propagate cancellation and bound underlying I/O;
    // the worker cancels and drains this call before releasing its claim.
    func deliver(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt?
}

public enum V2ForwardDeliveryError: Error, Equatable, Sendable {
    case invalidConfiguration
    case targetUnavailable
    case mediaPaused
    case receiptMismatch
    case timedOut
}

public struct V2ForwardDeliveryReport: Equatable, Sendable {
    public var claimed = 0
    public var completed = 0
    public var deferred = 0
    public var retried = 0
    public var paused = 0
    public var superseded = 0
}

/// One bounded concurrent batch. The runtime owns the loop and cancellation;
/// there are no detached delivery tasks and no remote I/O under a DB lock.
public struct V2ForwardDeliveryWorker: Sendable {
    private let store: PostgresV2ForwardDeliveryStore
    private let receipts: PostgresV2ForwardReceiptStore
    private let target: any V2ForwardExportDelivering
    private let leaseDuration: TimeInterval
    private let deliveryTimeout: TimeInterval
    private let pendingDelay: TimeInterval
    private let maximumConcurrency: Int
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(store: PostgresV2ForwardDeliveryStore, receipts: PostgresV2ForwardReceiptStore,
                target: any V2ForwardExportDelivering, leaseDuration: TimeInterval = 300,
                deliveryTimeout: TimeInterval? = nil, pendingDelay: TimeInterval = 1, maximumConcurrency: Int = 4,
                retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) throws {
        let timeout = deliveryTimeout ?? leaseDuration * 0.8
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= 3_600,
              timeout.isFinite, timeout > 0, timeout < leaseDuration,
              pendingDelay.isFinite, pendingDelay > 0, (1...1_024).contains(maximumConcurrency)
        else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.store = store; self.receipts = receipts; self.target = target
        self.leaseDuration = leaseDuration; self.pendingDelay = pendingDelay
        self.deliveryTimeout = timeout
        self.maximumConcurrency = maximumConcurrency; self.retryPolicy = retryPolicy; self.now = now
    }

    public func runOnce(sourceShardID: String, limit: Int) async throws -> V2ForwardDeliveryReport {
        guard limit > 0 else { throw V2ForwardDeliveryError.invalidConfiguration }
        try Task.checkCancellation()
        let leases = try await store.claim(sourceShardID: sourceShardID, now: now(), leaseDuration: leaseDuration, limit: min(limit, maximumConcurrency))
        return try await withThrowingTaskGroup(of: Result.self) { group in
            for lease in leases { group.addTask { try await deliver(lease) } }
            var report = V2ForwardDeliveryReport()
            report.claimed = leases.count
            for try await result in group {
                switch result {
                case .completed: report.completed += 1
                case .deferred: report.deferred += 1
                case .retried: report.retried += 1
                case .paused: report.paused += 1
                case .superseded: report.superseded += 1
                }
            }
            return report
        }
    }

    private enum Result: Sendable { case completed, deferred, retried, paused, superseded }

    private func requestTarget(_ export: V2ForwardExport) async throws -> V2ForwardTerminalReceipt? {
        try await withThrowingTaskGroup(of: V2ForwardTerminalReceipt?.self) { group in
            group.addTask { try await target.deliver(export) }
            group.addTask {
                try await Task.sleep(for: .seconds(deliveryTimeout))
                throw V2ForwardDeliveryError.timedOut
            }
            defer { group.cancelAll() }
            // The optional result is itself meaningful: unwrap only the
            // group's outer optional, preserving a pending nil from target.
            guard let result = try await group.next() else { throw V2ForwardDeliveryError.targetUnavailable }
            return result
        }
    }

    private func deliver(_ lease: V2ForwardDeliveryLease) async throws -> Result {
        do {
            try Task.checkCancellation()
            guard try await store.isCurrent(lease, now: now()) else { return .superseded }
            // Recover a crash after source receipt commit without target I/O.
            if try await receipts.status(exportID: lease.export.intent.exportID) != nil {
                return try await store.complete(lease, now: now()) ? .completed : .superseded
            }
            guard let receipt = try await requestTarget(lease.export) else {
                try Task.checkCancellation()
                let time = now()
                guard let retryAt = v2PostgresFutureTimestamp(now: time, interval: pendingDelay) else {
                    throw V2ForwardExportError.corruptPersistenceState
                }
                return try await store.reschedule(lease, disposition: .retry(at: retryAt), resetAttempts: true, now: time) ? .deferred : .superseded
            }
            guard receipt.export == lease.export else { throw V2ForwardDeliveryError.receiptMismatch }
            try Task.checkCancellation()
            guard try await store.isCurrent(lease, now: now()) else { return .superseded }
            try await receipts.record(receipt, now: now())
            return try await store.complete(lease, now: now()) ? .completed : .superseded
        } catch is CancellationError {
            _ = try? await store.reschedule(lease, disposition: .retry(at: now()), resetAttempts: true, now: now())
            throw CancellationError()
        } catch {
            let time = now()
            let disposition: V2DurableRetryDisposition = error as? V2ForwardDeliveryError == .mediaPaused
                ? .pause : retryPolicy.disposition(attempt: lease.attempt, claimToken: lease.claimToken, now: time)
            if case .retry(let retryAt) = disposition, !v2PostgresTimestampPrecedes(time, retryAt) {
                throw V2ForwardExportError.corruptPersistenceState
            }
            guard try await store.reschedule(lease, disposition: disposition, now: time) else { return .superseded }
            if case .pause = disposition { return .paused }
            return .retried
        }
    }
}
