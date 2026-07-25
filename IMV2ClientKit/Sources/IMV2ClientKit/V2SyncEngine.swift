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

    public func synchronizeOnce() async throws -> V2SyncCycleResult {
        try Task.checkCancellation()
        let cursorBeforePull = try await store.cursor()
        let pull = try await transport.pull(syncToken: cursorBeforePull?.syncToken, maxRecords: maxRecords)
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

    /// Pages become durable one by one before the server ACK. A later call
    /// resumes matching staged pages and atomically swaps only after every
    /// manifest page is present and verified by the transport/store fences.
    public func completePendingReset() async throws {
        guard let cursor = try await store.cursor(), let reset = cursor.pendingReset else {
            throw V2ClientSyncError.noResetPending
        }
        guard reset.expiresAt > Date() else { throw V2ClientSyncError.snapshotExpired }
        let manifest = try await transport.fetchSnapshotManifest(for: reset)
        guard manifest.reset == reset else { throw V2ClientSyncError.snapshotMismatch }
        guard manifest.capabilityProfile == capabilityProfile else { throw V2ClientSyncError.unsupportedCapabilityProfile }
        try await store.beginSnapshotStaging(manifest)
        let staged = try await store.stagedSnapshotPageIndexes(for: manifest)
        for index in manifest.pageDigests.indices where !staged.contains(index) {
            try Task.checkCancellation()
            let page = try await transport.fetchSnapshotPage(for: manifest, index: index)
            try await store.stageSnapshotPage(page, for: manifest)
        }
        try await store.commitStagedSnapshot(manifest)
        try Task.checkCancellation()
        try await transport.acknowledgeSnapshot(manifest)
        try await store.markSnapshotAcknowledged(snapshotID: reset.snapshotID, generation: reset.generation, baseSequence: reset.baseSequence, receipt: manifest.receipt)
    }
}
