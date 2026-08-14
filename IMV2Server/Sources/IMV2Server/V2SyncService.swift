import Foundation
import IMV2Core

public struct V2SyncRecord: Equatable, Sendable {
    public let sequence: UInt64
    public let sourceEventID: EventID
    public let projectionKind: String
    /// Canonical JSON supplied by the durable projection. Protocol adapters
    /// encode it as bytes; they do not reinterpret message semantics.
    public let payloadJSON: String

    public init(sequence: UInt64, sourceEventID: EventID, projectionKind: String, payloadJSON: String) {
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payloadJSON = payloadJSON
    }
}

public enum V2SyncPullResult: Equatable, Sendable {
    case ready(generation: UInt64, records: [V2SyncRecord], nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, hasMore: Bool)
    case resetPreparing(snapshotID: SnapshotID, generation: UInt64, retryAfter: TimeInterval)
    case resetRequired(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, expiresAt: Date)
}

public struct V2SnapshotManifest: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: UInt64
    public let baseSequence: UInt64
    public let rootDigest: String
    public let schemaVersion: UInt32
    public let capabilityProfile: String
    public let pageCount: UInt32
    public let totalItems: UInt64
    public let totalBytes: UInt64
    public let nextSyncToken: V2SyncToken
    public let receipt: V2SyncReceipt
    public let expiresAt: Date
}

public struct V2SnapshotPage: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: UInt64
    public let rootDigest: String
    public let index: UInt32
    public let firstKey: V2SnapshotProjectionKey
    public let lastKey: V2SnapshotProjectionKey
    public let itemCount: UInt32
    public let digest: String
    public let payload: Data
}

public protocol V2SyncStore: Sendable {
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, now: Date) async throws -> V2SyncPullResult
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage
    func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws
}

public struct V2SyncService: Sendable {
    private let store: any V2SyncStore
    private let maxRecordsLimit: Int
    private let now: @Sendable () -> Date

    public init(store: any V2SyncStore, maxRecordsLimit: Int = 500, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(maxRecordsLimit > 0)
        self.store = store
        self.maxRecordsLimit = maxRecordsLimit
        self.now = now
    }

    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, requestedMaxRecords: Int) async throws -> V2SyncPullResult {
        let limit = min(max(requestedMaxRecords, 1), maxRecordsLimit)
        return try await store.pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: limit, now: now())
    }

    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws {
        try await store.acknowledge(userID: userID, deviceID: deviceID, generation: generation, highestContiguousSequence: highestContiguousSequence, receipt: receipt, now: now())
    }

    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64) async throws -> V2SnapshotManifest {
        try await store.fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now())
    }

    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32) async throws -> V2SnapshotPage {
        try await store.fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index, now: now())
    }

    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt) async throws {
        try await store.acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now())
    }
}
