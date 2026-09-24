import Foundation
import IMV2Core

public enum V2ActorRoomRecoveryWireError: Error, Equatable, Sendable {
    case invalidBatch
    case invalidResult
}

/// One bounded collection read, preserving the existing SQL batch boundary.
public struct V2ActorRoomRecoveryBatchQueryWire: Codable, Equatable, Sendable {
    public static let maximumRoomCount = 100
    public let roomIDs: [RoomID]
    public let actorUserID: UserID

    public init(roomIDs: [RoomID], actorUserID: UserID) throws {
        guard (1...Self.maximumRoomCount).contains(roomIDs.count),
              Set(roomIDs).count == roomIDs.count else { throw V2ActorRoomRecoveryWireError.invalidBatch }
        self.roomIDs = roomIDs
        self.actorUserID = actorUserID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomIDs: values.decode([RoomID].self, forKey: .roomIDs),
                      actorUserID: values.decode(UserID.self, forKey: .actorUserID))
    }

    private enum CodingKeys: String, CodingKey { case roomIDs, actorUserID }
}

/// All fields are from one authorized room snapshot; owner epoch zero remains valid.
public struct V2ActorRoomSynchronizationStateWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let ownerEpoch: UInt64
    public let viewerMembershipRevision: UInt64
    public let head: UInt64
    public let trimmedThrough: UInt64
    public let readThrough: UInt64
    public let latestOwnMessageSequence: UInt64

    public init(roomID: RoomID, ownerEpoch: UInt64, viewerMembershipRevision: UInt64,
                head: UInt64, trimmedThrough: UInt64, readThrough: UInt64,
                latestOwnMessageSequence: UInt64) {
        self.roomID = roomID; self.ownerEpoch = ownerEpoch
        self.viewerMembershipRevision = viewerMembershipRevision
        self.head = head; self.trimmedThrough = trimmedThrough
        self.readThrough = readThrough; self.latestOwnMessageSequence = latestOwnMessageSequence
    }
}

public enum V2ActorRoomStateReadWire: Codable, Equatable, Sendable {
    case state(V2ActorRoomSynchronizationStateWire)
    case unavailable
    case retry
}

public struct V2ActorRoomStateItemWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let result: V2ActorRoomStateReadWire
    public init(roomID: RoomID, result: V2ActorRoomStateReadWire) {
        self.roomID = roomID; self.result = result
    }
}

public struct V2ActorRoomStateBatchWire: Codable, Equatable, Sendable {
    public let items: [V2ActorRoomStateItemWire]
    public init(items: [V2ActorRoomStateItemWire]) { self.items = items }
}

public struct V2ActorRoomLatestMessageWire: Codable, Equatable, Sendable {
    public let id: MessageID
    public let senderID: UserID
    public let sequence: UInt64
    public let revision: UInt64
    public let preview: String
    public let mediaCount: Int
    public let createdAt: Date

    public init(id: MessageID, senderID: UserID, sequence: UInt64, revision: UInt64,
                preview: String, mediaCount: Int, createdAt: Date) {
        self.id = id; self.senderID = senderID; self.sequence = sequence
        self.revision = revision; self.preview = preview
        self.mediaCount = mediaCount; self.createdAt = createdAt
    }
}

public struct V2ActorRoomLatestVisibleWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let ownerEpoch: UInt64
    public let membershipRevision: UInt64
    public let head: UInt64
    public let latest: V2ActorRoomLatestMessageWire?

    public init(roomID: RoomID, ownerEpoch: UInt64, membershipRevision: UInt64,
                head: UInt64, latest: V2ActorRoomLatestMessageWire?) {
        self.roomID = roomID; self.ownerEpoch = ownerEpoch
        self.membershipRevision = membershipRevision; self.head = head; self.latest = latest
    }
}

public enum V2ActorRoomLatestVisibleReadWire: Codable, Equatable, Sendable {
    case snapshot(V2ActorRoomLatestVisibleWire)
    case unavailable
    case retry
}

public struct V2ActorRoomLatestVisibleItemWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let result: V2ActorRoomLatestVisibleReadWire
    public init(roomID: RoomID, result: V2ActorRoomLatestVisibleReadWire) {
        self.roomID = roomID; self.result = result
    }
}

public struct V2ActorRoomLatestVisibleBatchWire: Codable, Equatable, Sendable {
    public let items: [V2ActorRoomLatestVisibleItemWire]
    public init(items: [V2ActorRoomLatestVisibleItemWire]) { self.items = items }
}

public enum V2RoomRecoveryQuery: Codable, Equatable, Sendable {
    case states(V2ActorRoomRecoveryBatchQueryWire)
    case latestVisible(V2ActorRoomRecoveryBatchQueryWire)

    public var roomIDs: [RoomID] {
        switch self {
        case .states(let query), .latestVisible(let query): query.roomIDs
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .states(let query), .latestVisible(let query): query.actorUserID
        }
    }
    public var replayPolicy: V2RoomReplayPolicy { .readOnly }
}

public enum V2ActorRoomRecoveryReadErrorWire: String, Codable, Equatable, Sendable {
    case invalidRequest, corruptPersistence, invalidCursor, topologyChanged
}

public enum V2RoomRecoveryResult: Codable, Equatable, Sendable {
    case failure(V2ActorRoomRecoveryReadErrorWire)
    case states(V2ActorRoomStateBatchWire)
    case latestVisible(V2ActorRoomLatestVisibleBatchWire)
}
