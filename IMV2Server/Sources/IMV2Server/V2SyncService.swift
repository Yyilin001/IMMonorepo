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
    case resetRequired(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, manifestDigest: String, expiresAt: Date)
}

public struct V2SnapshotStage: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let baseSequence: UInt64
    public let manifestDigest: String
    public let nextSyncToken: V2SyncToken
    public let receipt: V2SyncReceipt
    public let expiresAt: Date
    public let schemaVersion: UInt32
    public let capabilityProfile: String
    public let pages: [V2SnapshotPageStage]

    public init(snapshotID: SnapshotID, baseSequence: UInt64, manifestDigest: String, nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, expiresAt: Date, schemaVersion: UInt32, capabilityProfile: String, pages: [V2SnapshotPageStage]) {
        self.snapshotID = snapshotID
        self.baseSequence = baseSequence
        self.manifestDigest = manifestDigest
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.expiresAt = expiresAt
        self.schemaVersion = schemaVersion
        self.capabilityProfile = capabilityProfile
        self.pages = pages
    }
}

/// Snapshot bytes are staged before the reset fence commits. Their digests are
/// supplied by the snapshot builder and never recomputed from mutable live
/// projections at read time.
public struct V2SnapshotPageStage: Equatable, Sendable {
    public let digest: String
    public let payload: Data

    public init(digest: String, payload: Data) {
        self.digest = digest
        self.payload = payload
    }
}

public struct V2SnapshotManifest: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: UInt64
    public let baseSequence: UInt64
    public let manifestDigest: String
    public let schemaVersion: UInt32
    public let capabilityProfile: String
    public let pageDigests: [String]
    public let nextSyncToken: V2SyncToken
    public let receipt: V2SyncReceipt
    public let expiresAt: Date
}

public struct V2SnapshotPage: Equatable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: UInt64
    public let manifestDigest: String
    public let index: UInt32
    public let digest: String
    public let payload: Data
}

public protocol V2SyncStore: Sendable {
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, now: Date) async throws -> V2SyncPullResult
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws
    func stageReset(userID: UserID, deviceID: DeviceID, snapshot: V2SnapshotStage, now: Date) async throws -> UInt64
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, manifestDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage
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

    public func stageReset(userID: UserID, deviceID: DeviceID, snapshot: V2SnapshotStage) async throws -> UInt64 {
        guard snapshot.schemaVersion == V2SnapshotProjectionCodec.schemaVersion,
              !snapshot.pages.isEmpty
        else { throw V2SnapshotProjectionError.unsupportedSchemaVersion }
        var messageIDs = Set<MessageID>()
        var roomPositions = Set<String>()
        var sourceEventIDs = Set<EventID>()
        var relationshipTargets = Set<UserID>()
        var blockTargets = Set<UserID>()
        var hasStrangerMessagePreference = false
        for page in snapshot.pages {
            let decoded = try V2SnapshotProjectionCodec.decodePage(page.payload)
            for message in decoded.messages {
                guard messageIDs.insert(message.messageID).inserted,
                      roomPositions.insert("\(message.roomID.rawValue):\(message.roomSequence)").inserted,
                      sourceEventIDs.insert(message.sourceEventID).inserted
                else { throw V2SnapshotProjectionError.invalidPage }
            }
            for action in decoded.moderationActions {
                guard roomPositions.insert("\(action.roomID.rawValue):\(action.roomSequence)").inserted,
                      sourceEventIDs.insert(action.sourceEventID).inserted
                else { throw V2SnapshotProjectionError.invalidPage }
            }
            for control in decoded.roomControls {
                guard roomPositions.insert("\(control.roomID.rawValue):\(control.roomSequence)").inserted,
                      sourceEventIDs.insert(control.sourceEventID).inserted
                else { throw V2SnapshotProjectionError.invalidPage }
            }
            guard decoded.relationships.allSatisfy({ relationshipTargets.insert($0.targetUserID).inserted }),
                  decoded.userBlocks.allSatisfy({ blockTargets.insert($0.targetUserID).inserted }),
                  !hasStrangerMessagePreference || decoded.strangerMessagePreference == nil
            else { throw V2SnapshotProjectionError.invalidPage }
            hasStrangerMessagePreference = hasStrangerMessagePreference || decoded.strangerMessagePreference != nil
        }
        return try await store.stageReset(userID: userID, deviceID: deviceID, snapshot: snapshot, now: now())
    }

    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64) async throws -> V2SnapshotManifest {
        try await store.fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now())
    }

    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, manifestDigest: String, index: UInt32) async throws -> V2SnapshotPage {
        try await store.fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, manifestDigest: manifestDigest, index: index, now: now())
    }

    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt) async throws {
        try await store.acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now())
    }
}
