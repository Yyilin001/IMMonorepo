import Foundation
import IMV2Core

/// Coalesces independent heartbeat renewals into bounded database statements.
/// Admission and removal remain immediate because they enforce connection
/// ownership; only renewal, whose rows are already owned, is batched.
public actor V2LivePresenceRenewalBatcher {
    /// These generations only identify actor-local continuations and delayed
    /// flushes. They are neither public identifiers nor authorization tokens,
    /// so a monotonic counter provides the required uniqueness without
    /// opening the platform random source for every heartbeat.
    private typealias Generation = UInt64

    public struct Configuration: Equatable, Sendable {
        public let maximumBatchSize: Int
        public let maximumDelay: Duration

        public init(
            maximumBatchSize: Int = 256,
            maximumDelay: Duration = .milliseconds(2)
        ) {
            precondition(maximumBatchSize > 0)
            precondition(maximumDelay >= .zero)
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let pendingConnections: Int
        public let submittedRequests: UInt64
        public let executedBatches: UInt64
        public let failedBatches: UInt64
        public let largestBatch: Int

        public init(
            pendingConnections: Int,
            submittedRequests: UInt64,
            executedBatches: UInt64,
            failedBatches: UInt64,
            largestBatch: Int
        ) {
            self.pendingConnections = pendingConnections
            self.submittedRequests = submittedRequests
            self.executedBatches = executedBatches
            self.failedBatches = failedBatches
            self.largestBatch = largestBatch
        }
    }

    private struct PendingRenewal {
        var request: V2LivePresenceLeaseRenewalRequest
        var continuations: [Generation: CheckedContinuation<V2LivePresenceLeaseRefresh, any Error>]
    }

    private let leases: any V2LivePresenceLeaseManaging
    private let configuration: Configuration
    private var pending: [UUID: PendingRenewal] = [:]
    private var scheduledFlushID: Generation?
    private var scheduledFlush: Task<Void, Never>?
    private var scheduledFlushIsImmediate = false
    private var nextGeneration: Generation = 0
    private var submittedRequests: UInt64 = 0
    private var executedBatches: UInt64 = 0
    private var failedBatches: UInt64 = 0
    private var largestBatch = 0

    public init(
        leases: any V2LivePresenceLeaseManaging,
        configuration: Configuration = .init()
    ) {
        self.leases = leases
        self.configuration = configuration
    }

    public func renew(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> V2LivePresenceLeaseRefresh {
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let continuationID = makeGeneration()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submittedRequests &+= 1
                let request = V2LivePresenceLeaseRenewalRequest(
                    identity: identity,
                    connectionID: connectionID,
                    now: now
                )
                if var existing = pending[connectionID] {
                    if existing.request.now <= now { existing.request = request }
                    existing.continuations[continuationID] = continuation
                    pending[connectionID] = existing
                } else {
                    pending[connectionID] = .init(
                        request: request,
                        continuations: [continuationID: continuation]
                    )
                }
                if pending.count >= configuration.maximumBatchSize {
                    if !scheduledFlushIsImmediate { scheduleFlush(after: .zero) }
                } else if scheduledFlush == nil {
                    scheduleFlush(after: configuration.maximumDelay)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(connectionID: connectionID, continuationID: continuationID) }
        }
    }

    public func snapshot() -> Snapshot {
        .init(
            pendingConnections: pending.count,
            submittedRequests: submittedRequests,
            executedBatches: executedBatches,
            failedBatches: failedBatches,
            largestBatch: largestBatch
        )
    }

    public func finish() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        scheduledFlushID = nil
        scheduledFlushIsImmediate = false
        let remaining = pending.values.flatMap { $0.continuations.values }
        pending.removeAll(keepingCapacity: false)
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }

    private func scheduleFlush(after delay: Duration) {
        scheduledFlush?.cancel()
        let flushID = makeGeneration()
        scheduledFlushID = flushID
        scheduledFlushIsImmediate = delay == .zero
        scheduledFlush = Task {
            do { try await Task.sleep(for: delay) }
            catch { return }
            await self.flush(scheduledID: flushID)
        }
    }

    private func flush(scheduledID: Generation) async {
        guard scheduledFlushID == scheduledID else { return }
        scheduledFlushID = nil
        scheduledFlush = nil
        scheduledFlushIsImmediate = false
        let connectionIDs = Array(pending.keys.prefix(configuration.maximumBatchSize))
        var batch: [UUID: PendingRenewal] = [:]
        batch.reserveCapacity(connectionIDs.count)
        for connectionID in connectionIDs {
            batch[connectionID] = pending.removeValue(forKey: connectionID)
        }
        if !pending.isEmpty { scheduleFlush(after: .zero) }
        guard !batch.isEmpty else { return }

        executedBatches &+= 1
        largestBatch = max(largestBatch, batch.count)
        do {
            let results = try await leases.renewConnections(batch.values.map(\.request))
            for (connectionID, item) in batch {
                // A missing row is a rejected renewal. Failing closed here
                // keeps an expired or identity-mismatched lease from being
                // resurrected by an incomplete store implementation.
                let refresh = results[connectionID] ?? .init(
                    outcome: .rejected,
                    allowsOnlinePresence: false
                )
                for continuation in item.continuations.values {
                    continuation.resume(returning: refresh)
                }
            }
        } catch {
            failedBatches &+= 1
            for item in batch.values {
                for continuation in item.continuations.values {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cancelPending(connectionID: UUID, continuationID: Generation) {
        guard var item = pending[connectionID],
              let continuation = item.continuations.removeValue(forKey: continuationID)
        else { return }
        if item.continuations.isEmpty {
            pending.removeValue(forKey: connectionID)
        } else {
            pending[connectionID] = item
        }
        continuation.resume(throwing: CancellationError())
    }

    private func makeGeneration() -> Generation {
        nextGeneration &+= 1
        precondition(nextGeneration != 0, "live presence renewal generation exhausted")
        return nextGeneration
    }
}
