import Foundation
import IMV2ActorContracts

public struct V2RealtimeJournalEntry: Codable, Equatable, Sendable {
    public let partitionID: Int
    public let sequence: Int64
    public let sourceEventID: UUID
    public let topicKind: String
    public let topicID: String
    public let changeKind: String
    public let ownerEpoch: Int64?
    public let roomSequence: Int64?
    public let roomControlVersion: Int64?
    public let userControlVersion: Int64?
    public let deviceID: UUID?
    /// Target of a user membership invalidation; never itself an authorization grant.
    public let membershipRoomID: UUID?
    public init(partitionID: Int, sequence: Int64, sourceEventID: UUID, topicKind: String,
                topicID: String, changeKind: String, roomSequence: Int64? = nil, ownerEpoch: Int64? = nil,
                roomControlVersion: Int64? = nil, userControlVersion: Int64? = nil, deviceID: UUID? = nil, membershipRoomID: UUID? = nil) {
        self.partitionID = partitionID; self.sequence = sequence; self.sourceEventID = sourceEventID
        self.topicKind = topicKind; self.topicID = topicID; self.changeKind = changeKind
        self.ownerEpoch = ownerEpoch; self.roomSequence = roomSequence; self.roomControlVersion = roomControlVersion
        self.userControlVersion = userControlVersion; self.deviceID = deviceID
        self.membershipRoomID = membershipRoomID
    }
}

/// A snapshot and its entries are read in one database statement. A trimmed
/// checkpoint requires an authorization snapshot before installing new coverage.
public struct V2RealtimeJournalBatch: Codable, Equatable, Sendable {
    public let partitionID: Int
    public let publishedThrough: Int64
    public let trimmedThrough: Int64
    public let requiresSnapshot: Bool
    public let entries: [V2RealtimeJournalEntry]
    public init(partitionID: Int, publishedThrough: Int64, trimmedThrough: Int64,
                requiresSnapshot: Bool, entries: [V2RealtimeJournalEntry]) {
        self.partitionID = partitionID; self.publishedThrough = publishedThrough
        self.trimmedThrough = trimmedThrough; self.requiresSnapshot = requiresSnapshot; self.entries = entries
    }
}

public enum V2RealtimeJournalError: Error, Equatable, Sendable {
    case invalidInput, authorityLost, corruptPersistenceState
}

public protocol V2RealtimeChangeJournalStore: V2RealtimePartitionLeaseStore {
    func pendingPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int]
    func publishPending(lease: V2RealtimePartitionLease, limit: Int) async throws -> V2RealtimeJournalBatch
    func replay(partitionID: Int, after: Int64, limit: Int) async throws -> V2RealtimeJournalBatch
    func trim(lease: V2RealtimePartitionLease, through: Int64) async throws
}

/// Returned only after the local shared projection or authorization snapshot has
/// actually been installed. RPC acceptance and queue admission cannot produce it.
public struct V2RealtimeJournalApplyResult: Equatable, Sendable {
    public let sourceID: String
    public let partitionID: Int
    public let appliedThrough: Int64
    public let snapshotInstalled: Bool
    public init(sourceID: String, partitionID: Int, appliedThrough: Int64, snapshotInstalled: Bool = false) {
        self.sourceID = sourceID; self.partitionID = partitionID
        self.appliedThrough = appliedThrough; self.snapshotInstalled = snapshotInstalled
    }
}

public struct V2RealtimeJournalSourceIdentity: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let databaseIncarnation: UUID
    public init(sourceID: UUID, databaseIncarnation: UUID) {
        self.sourceID = sourceID; self.databaseIncarnation = databaseIncarnation
    }
}
public struct V2RealtimeJournalViewerKey: Codable, Hashable, Sendable {
    public let roomID: UUID
    public let userID: UUID
    public init(roomID: UUID, userID: UUID) { self.roomID = roomID; self.userID = userID }
}
public struct V2RealtimeJournalRoomProjection: Codable, Equatable, Sendable {
    public let roomID: UUID
    public let roomSequence: Int64
    public let ownerEpoch: Int64
    public let roomControlVersion: Int64
    public let frozen: Bool
    public let exists: Bool
    public init(roomID: UUID, roomSequence: Int64, ownerEpoch: Int64, roomControlVersion: Int64, frozen: Bool, exists: Bool = true) {
        self.roomID = roomID; self.roomSequence = roomSequence; self.ownerEpoch = ownerEpoch
        self.roomControlVersion = roomControlVersion; self.frozen = frozen; self.exists = exists
    }
}
public struct V2RealtimeJournalViewerProjection: Codable, Equatable, Sendable {
    public let roomID: UUID
    public let userID: UUID
    public let active: Bool
    public let joinedRevision: Int64?
    public let role: String?
    public let roomControlVersion: Int64
    public init(roomID: UUID, userID: UUID, active: Bool, joinedRevision: Int64?, role: String?, roomControlVersion: Int64) {
        self.roomID = roomID; self.userID = userID; self.active = active
        self.joinedRevision = joinedRevision; self.role = role; self.roomControlVersion = roomControlVersion
    }
}
public struct V2RealtimeJournalPartitionCut: Codable, Equatable, Sendable {
    public let partitionID: Int
    public let publishedThrough: Int64
    public let trimmedThrough: Int64
    public init(partitionID: Int, publishedThrough: Int64, trimmedThrough: Int64) {
        self.partitionID = partitionID; self.publishedThrough = publishedThrough; self.trimmedThrough = trimmedThrough
    }
}
/// Current authoritative state and journal cuts share one REPEATABLE READ MVCC
/// snapshot. Committed control outbox rows can be ahead of the published cut.
/// Install each room's control-version floor atomically with its grants/head;
/// subsequent controls <= that floor cannot replace grants. Newer controls must
/// refresh authoritative state before grants become Ready. This is a proved
/// current-state snapshot, never a claimed historical snapshot at an old cut.
public struct V2RealtimeJournalProjectionSnapshot: Codable, Equatable, Sendable {
    public let identity: V2RealtimeJournalSourceIdentity
    public let cuts: [V2RealtimeJournalPartitionCut]
    public let rooms: [V2RealtimeJournalRoomProjection]
    public let viewers: [V2RealtimeJournalViewerProjection]
    public init(identity: V2RealtimeJournalSourceIdentity, cuts: [V2RealtimeJournalPartitionCut],
                rooms: [V2RealtimeJournalRoomProjection], viewers: [V2RealtimeJournalViewerProjection]) {
        self.identity = identity; self.cuts = cuts; self.rooms = rooms; self.viewers = viewers
    }
}
public protocol V2RealtimeJournalProjectionStore: V2RealtimeChangeJournalStore {
    func sourceIdentity() async throws -> V2RealtimeJournalSourceIdentity
    func projectionSnapshot(roomIDs: [UUID], viewerKeys: [V2RealtimeJournalViewerKey], partitionIDs: [Int],
                            minimumPublishedThrough: [Int: Int64]) async throws -> V2RealtimeJournalProjectionSnapshot
}

/// A reliable, coalescible room head hint. This is not a client/user ACK and
/// contains no message body. Revision protects ACK from a concurrently dirtied H.
public struct V2RealtimeRoomHeadChange: Codable, Equatable, Sendable {
    public let partitionID: Int
    public let roomID: UUID
    public let roomSequence: Int64
    public let ownerEpoch: Int64
    public let roomControlVersion: Int64
    public let revision: Int64
    public var topic: V2RealtimeTopicKey { .init(kind: .roomEvents, id: roomID.uuidString.lowercased()) }
    public init(partitionID: Int, roomID: UUID, roomSequence: Int64, ownerEpoch: Int64,
                roomControlVersion: Int64, revision: Int64) {
        self.partitionID = partitionID; self.roomID = roomID; self.roomSequence = roomSequence
        self.ownerEpoch = ownerEpoch; self.roomControlVersion = roomControlVersion; self.revision = revision
    }
}
public protocol V2RealtimeRoomHeadChangeStore: Sendable {
    func pendingRoomHeadPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int]
    func pendingRoomHeads(lease: V2RealtimePartitionLease, limit: Int) async throws -> [V2RealtimeRoomHeadChange]
    func acknowledgeRoomHeads(lease: V2RealtimePartitionLease, heads: [V2RealtimeRoomHeadChange]) async throws
}

/// Shared source-partition reconciliation. No viewer grants or recipient queue
/// are implied. Callers page actual room interests in batches of at most 256.
public struct V2RealtimeRoomHeadSnapshot: Codable, Equatable, Sendable {
    public let identity: V2RealtimeJournalSourceIdentity
    public let partitionID: Int
    public let cut: V2RealtimeJournalPartitionCut
    public let rooms: [V2RealtimeJournalRoomProjection]
    public init(identity: V2RealtimeJournalSourceIdentity, partitionID: Int,
                cut: V2RealtimeJournalPartitionCut, rooms: [V2RealtimeJournalRoomProjection]) {
        self.identity = identity; self.partitionID = partitionID; self.cut = cut; self.rooms = rooms
    }
}
public protocol V2RealtimeRoomHeadAntiEntropyStore: Sendable {
    func roomHeadSnapshot(roomIDs: [UUID], partitionID: Int) async throws -> V2RealtimeRoomHeadSnapshot
}
