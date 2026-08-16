import Foundation
import IMV2Core

public enum V2SyncCycleResult: Equatable, Sendable {
    case synchronized(appliedThrough: UInt64, hasMore: Bool)
    case resetPending(V2ClientResetRequired)
}

/// Owns the client sync state machine. The actor serializes pull/apply/ack so
/// a reconnect cannot race a local transaction or ACK an unpersisted batch.
public actor V2SyncEngine: V2SyncDriving {
    private let transport: any V2ClientSyncTransport
    private let store: any V2LocalSyncStore
    private let maxRecords: Int
    private let capabilityProfile: String
    private var retiredSnapshotCleanupTask: Task<Void, Never>?

    public init(
        transport: any V2ClientSyncTransport,
        store: any V2LocalSyncStore,
        capabilityProfile: String,
        maxRecords: Int = 500
    ) {
        precondition(maxRecords > 0 && !capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.transport = transport
        self.store = store
        self.capabilityProfile = capabilityProfile
        self.maxRecords = maxRecords
    }

    deinit {
        retiredSnapshotCleanupTask?.cancel()
    }

    public func synchronizeOnce() async throws -> V2SyncCycleResult {
        try Task.checkCancellation()
        let cursorBeforePull = try await store.cursor()
        // A restart may happen after the server committed the snapshot ACK but
        // before the local shadow projection was activated. Do not send the
        // old continuation token in that state; resume the durable import and
        // replay the idempotent snapshot ACK first.
        if let cursorBeforePull, let reset = cursorBeforePull.pendingReset {
            return .resetPending(reset)
        }
        let pull: V2ClientPullResult
        do {
            pull = try await transport.pull(
                syncToken: cursorBeforePull?.syncToken,
                maxRecords: maxRecords
            )
        } catch let error as V2RealtimeTransportError {
            guard case .server(code: "SYNC_TOKEN_INVALID", retryable: false, _, _) = error,
                  let cursorBeforePull
            else { throw error }
            try await store.discardSyncCapabilities(generation: cursorBeforePull.generation)
            pull = try await transport.pull(syncToken: nil, maxRecords: maxRecords)
        }
        switch pull {
        case .ready(let batch):
            guard batch.capabilityProfile == capabilityProfile else { throw V2ClientSyncError.unsupportedCapabilityProfile }
            let cursor = try await store.apply(batch)
            guard cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            if let receipt = cursor.pendingAcknowledgementReceipt,
               let sequence = cursor.pendingAcknowledgementSequence
            {
                try Task.checkCancellation()
                try await transport.acknowledge(generation: cursor.generation, highestContiguousSequence: sequence, receipt: receipt)
                try await store.markServerAcknowledged(generation: cursor.generation, sequence: sequence, receipt: receipt)
            }
            return .synchronized(appliedThrough: cursor.appliedSequence, hasMore: batch.hasMore)
        case .resetRequired(let reset):
            try await store.beginReset(reset)
            return .resetPending(reset)
        }
    }

    /// Drains consecutive batches after a live hint, foreground resume, or
    /// reconnect. The return value still distinguishes reset from readiness.
    public func synchronizeUntilCaughtUp() async throws -> V2SyncCycleResult {
        while true {
            let result = try await synchronizeOnce()
            guard case .synchronized(_, let hasMore) = result, hasMore else { return result }
        }
    }

    /// Each page is decoded and applied into a durable shadow projection in a
    /// bounded SQLite transaction. The server generation is committed before
    /// the live local projection is replaced, closing the otherwise unsafe
    /// activate-before-ACK crash window.
    public func completePendingReset() async throws {
        guard let cursor = try await store.cursor(), let reset = cursor.pendingReset else {
            throw V2ClientSyncError.noResetPending
        }
        let manifest: V2ClientSnapshotManifest
        if let imported = try await store.importedSnapshotManifest(for: reset) {
            manifest = imported
        } else {
            do {
                manifest = try await transport.fetchSnapshotManifest(for: reset)
            } catch let error as V2RealtimeTransportError {
                try await cancelResetIfRejected(error, reset: reset)
                throw error
            }
        }
        guard manifest.reset == reset else { throw V2ClientSyncError.snapshotMismatch }
        guard manifest.capabilityProfile == capabilityProfile else { throw V2ClientSyncError.unsupportedCapabilityProfile }
        try await store.beginSnapshotImport(
            manifest,
            initialDigest: V2SnapshotV3Digest.initial(
                baseSequence: manifest.reset.baseSequence,
                capabilityProfile: manifest.capabilityProfile
            )
        )
        var index = try await store.nextSnapshotPageIndex(for: manifest)
        while index < manifest.pageCount {
            try Task.checkCancellation()
            let page: V2ClientSnapshotPage
            do {
                page = try await transport.fetchSnapshotPage(for: manifest, index: index)
            } catch let error as V2RealtimeTransportError {
                try await cancelResetIfRejected(error, reset: reset)
                throw error
            }
            try await store.applySnapshotPage(page, for: manifest)
            index += 1
        }
        try Task.checkCancellation()
        try await store.prepareSnapshotActivation(manifest)
        do {
            try await transport.acknowledgeSnapshot(manifest)
        } catch let error as V2RealtimeTransportError {
            try await cancelResetIfRejected(error, reset: reset)
            throw error
        }
        try await store.activateAcknowledgedSnapshot(manifest)
        // Reclaiming the old b-trees can touch every retired page. It is safe
        // to run after the cursor fence is visible and must never extend the
        // acknowledged-snapshot activation transaction. The engine owns this
        // best-effort task so replacement/deinitialization can cancel it; it
        // is not an orphaned task that silently outlives the sync lifecycle.
        retiredSnapshotCleanupTask?.cancel()
        retiredSnapshotCleanupTask = Task { [store] in
            guard !Task.isCancelled else { return }
            try? await store.cleanupRetiredSnapshotTables()
        }
    }

    private func cancelResetIfRejected(
        _ error: V2RealtimeTransportError,
        reset: V2ClientResetRequired
    ) async throws {
        // RESET_REQUIRED is a terminal fence result for this exact reset: the
        // server either expired and rolled it back or superseded it. The live
        // projection was never replaced, so restoring the old cursor is safe.
        if case .server(code: "RESET_REQUIRED", retryable: false, _, _) = error {
            try await store.cancelReset(reset)
        }
    }

}
