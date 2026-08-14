import Foundation
import IMV2Core

public struct V2ClientSyncRecord: Equatable, Sendable {
    public let sequence: UInt64
    public let sourceEventID: EventID
    public let projectionKind: String
    public let payload: Data

    public init(sequence: UInt64, sourceEventID: EventID, projectionKind: String, payload: Data) {
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

public struct V2ClientSyncBatch: Equatable, Sendable {
    public let generation: UInt64
    public let records: [V2ClientSyncRecord]
    public let nextSyncToken: V2SyncToken
    public let receipt: V2SyncReceipt
    public let hasMore: Bool
    public let capabilityProfile: String

    public init(generation: UInt64, records: [V2ClientSyncRecord], nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, hasMore: Bool, capabilityProfile: String) {
        self.generation = generation
        self.records = records
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.hasMore = hasMore
        self.capabilityProfile = capabilityProfile
    }
}

public struct V2ClientResetRequired: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: UInt64
    public let baseSequence: UInt64
    public let expiresAt: Date

    public init(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, expiresAt: Date) {
        self.snapshotID = snapshotID
        self.generation = generation
        self.baseSequence = baseSequence
        self.expiresAt = expiresAt
    }
}

public enum V2ClientPullResult: Equatable, Sendable {
    case ready(V2ClientSyncBatch)
    case resetRequired(V2ClientResetRequired)
}

public struct V2ClientSnapshotManifest: Equatable, Sendable {
    public let reset: V2ClientResetRequired
    public let rootDigest: String
    public let pageCount: Int
    public let totalItems: UInt64
    public let totalBytes: UInt64
    public let nextSyncToken: V2SyncToken
    public let receipt: V2SyncReceipt
    public let capabilityProfile: String

    public init(reset: V2ClientResetRequired, rootDigest: String, pageCount: Int, totalItems: UInt64, totalBytes: UInt64, nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, capabilityProfile: String) throws {
        guard (0 ... V2SnapshotProjectionV3Codec.maximumPageCount).contains(pageCount),
              totalItems <= V2SnapshotProjectionV3Codec.maximumTotalItems,
              totalBytes <= V2SnapshotProjectionV3Codec.maximumTotalBytes,
              (pageCount == 0) == (totalItems == 0),
              (pageCount == 0) == (totalBytes == 0),
              pageCount == 0 || (
                  totalItems >= UInt64(pageCount)
                  && totalItems <= UInt64(pageCount * V2SnapshotProjectionV3Codec.maximumPageItems)
                  && totalBytes >= UInt64(pageCount)
              )
        else { throw V2ClientSyncError.snapshotMismatch }
        self.reset = reset
        self.rootDigest = rootDigest
        self.pageCount = pageCount
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.capabilityProfile = capabilityProfile
    }
}

public struct V2ClientSnapshotPage: Equatable, Sendable {
    public let index: Int
    public let digest: String
    public let firstKey: V2SnapshotProjectionKey
    public let lastKey: V2SnapshotProjectionKey
    public let itemCount: Int
    public let payload: Data

    public init(index: Int, digest: String, firstKey: V2SnapshotProjectionKey, lastKey: V2SnapshotProjectionKey, itemCount: Int, payload: Data) {
        self.index = index
        self.digest = digest
        self.firstKey = firstKey
        self.lastKey = lastKey
        self.itemCount = itemCount
        self.payload = payload
    }
}

public enum V2ClientSyncError: Error, Equatable, Sendable {
    /// The wire protocol uses unsigned 64-bit sequence values, while the
    /// durable SQLite schema uses signed `INTEGER` / `BIGINT` values.
    case storageRangeExceeded
    case invalidRecordOrdering
    case generationMismatch
    case resetPending
    case noResetPending
    case resetFenceMismatch
    case snapshotMismatch
    case snapshotProjectionConflict
    case acknowledgementReceiptMismatch
    case unsupportedCapabilityProfile
}

public struct V2LocalSyncCursor: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case ready, resetPending }
    public let state: State
    public let generation: UInt64
    public let appliedSequence: UInt64
    public let serverAcknowledgedSequence: UInt64
    /// Must be persisted in the same SQLite transaction as `appliedSequence`.
    public let syncToken: V2SyncToken?
    /// Present only while a locally committed range still awaits its matching
    /// server ACK; a process restart may safely retry this exact receipt.
    public let pendingAcknowledgementReceipt: V2SyncReceipt?
    public let pendingAcknowledgementSequence: UInt64?
    public let pendingReset: V2ClientResetRequired?

    public init(
        state: State,
        generation: UInt64,
        appliedSequence: UInt64,
        serverAcknowledgedSequence: UInt64,
        syncToken: V2SyncToken?,
        pendingAcknowledgementReceipt: V2SyncReceipt?,
        pendingAcknowledgementSequence: UInt64?,
        pendingReset: V2ClientResetRequired?
    ) throws {
        guard generation > 0, serverAcknowledgedSequence <= appliedSequence else {
            throw V2ClientSyncError.generationMismatch
        }
        let hasPendingAcknowledgement = pendingAcknowledgementReceipt != nil || pendingAcknowledgementSequence != nil
        let validPendingAcknowledgement: Bool
        if pendingAcknowledgementReceipt != nil, let pendingAcknowledgementSequence {
            validPendingAcknowledgement = state == .ready &&
                pendingAcknowledgementSequence <= appliedSequence &&
                pendingAcknowledgementSequence > serverAcknowledgedSequence
        } else {
            validPendingAcknowledgement = false
        }
        guard !hasPendingAcknowledgement || validPendingAcknowledgement else {
            throw V2ClientSyncError.acknowledgementReceiptMismatch
        }
        guard (state == .ready) == (pendingReset == nil) else {
            throw V2ClientSyncError.resetFenceMismatch
        }
        self.state = state
        self.generation = generation
        self.appliedSequence = appliedSequence
        self.serverAcknowledgedSequence = serverAcknowledgedSequence
        self.syncToken = syncToken
        self.pendingAcknowledgementReceipt = pendingAcknowledgementReceipt
        self.pendingAcknowledgementSequence = pendingAcknowledgementSequence
        self.pendingReset = pendingReset
    }
}

public protocol V2ClientSyncTransport: Sendable {
    func pull(syncToken: V2SyncToken?, maxRecords: Int) async throws -> V2ClientPullResult
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest
    func fetchSnapshotPage(for manifest: V2ClientSnapshotManifest, index: Int) async throws -> V2ClientSnapshotPage
    func acknowledgeSnapshot(_ manifest: V2ClientSnapshotManifest) async throws
}

public protocol V2LocalSyncStore: Sendable {
    func cursor() async throws -> V2LocalSyncCursor?
    func discardSyncCapabilities(generation: UInt64) async throws
    func apply(_ batch: V2ClientSyncBatch) async throws -> V2LocalSyncCursor
    func markServerAcknowledged(generation: UInt64, sequence: UInt64, receipt: V2SyncReceipt) async throws
    func beginReset(_ reset: V2ClientResetRequired) async throws
    func cancelReset(_ reset: V2ClientResetRequired) async throws
    func importedSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest?
    func beginSnapshotImport(_ manifest: V2ClientSnapshotManifest, initialDigest: String) async throws
    func nextSnapshotPageIndex(for manifest: V2ClientSnapshotManifest) async throws -> Int
    func applySnapshotPage(_ page: V2ClientSnapshotPage, for manifest: V2ClientSnapshotManifest) async throws
    /// Finishes all data-proportional work against private shadow tables while
    /// the server still considers the old generation active. Once this
    /// returns, projection writes are fenced until activation or reset
    /// cancellation so the prepared bank cannot become stale.
    func prepareSnapshotActivation(_ manifest: V2ClientSnapshotManifest) async throws
    /// Must be called only after the server has durably acknowledged the
    /// matching, prepared snapshot. Swaps table names and advances the local
    /// generation fence in one bounded schema transaction.
    func activateAcknowledgedSnapshot(_ manifest: V2ClientSnapshotManifest) async throws
    /// Reclaims the retired table bank after activation. It is deliberately
    /// separate from activation because freeing a large SQLite b-tree is
    /// data-proportional maintenance, not part of the ACK critical section.
    func cleanupRetiredSnapshotTables() async throws
}
