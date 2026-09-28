import Foundation
import IMV2Core

public enum V2ActorRoomCreationResult: Codable, Equatable, Sendable {
    case provenDirect(V2DirectRoomOperationResult)
    case provenGroup(V2GroupCreationOperationResult)
}

/// 控制域发往所有者的内部引导身份；不得将其作为未经认证的网关命令接受。
public struct V2ActorGroupCreationIntentWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let roomID: RoomID
    public let eventID: EventID
    public let roomShardID: String
    public let routeEpoch: Int64
    public let requestFingerprint: Data
    public let audienceMemberCount: Int
    public let state: V2ActorGroupCreationIntentStateWire
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, roomID: RoomID, eventID: EventID, roomShardID: String, routeEpoch: Int64, requestFingerprint: Data, audienceMemberCount: Int, state: V2ActorGroupCreationIntentStateWire) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.roomID = roomID; self.eventID = eventID
        self.roomShardID = roomShardID; self.routeEpoch = routeEpoch; self.requestFingerprint = requestFingerprint
        self.audienceMemberCount = audienceMemberCount; self.state = state
    }
}
public enum V2ActorGroupCreationIntentStateWire: String, Codable, Equatable, Sendable { case prepared, committed }

public struct V2ActorGroupCreationManifestSliceWire: Codable, Equatable, Sendable {
    public let memberUserIDs: [UserID]
    public let hasMore: Bool
    public init(memberUserIDs: [UserID], hasMore: Bool) { self.memberUserIDs = memberUserIDs; self.hasMore = hasMore }
}
public struct V2ActorGroupCreationManifestPageWire: Codable, Equatable, Sendable {
    public let pageNumber: Int
    public let memberUserIDs: [UserID]
    public let isFinal: Bool
    public let digest: Data
    public init(pageNumber: Int, memberUserIDs: [UserID], isFinal: Bool, digest: Data) {
        self.pageNumber = pageNumber; self.memberUserIDs = memberUserIDs; self.isFinal = isFinal; self.digest = digest
    }
}
public enum V2ActorRoomCreationErrorWire: String, Codable, Error, Equatable, Sendable {
    case selfTargetingNotAllowed, invalidTitle, invalidInitialMembers, invalidMemberCount
    case invalidInput, missingDraft, draftFrozen, memberLimitReached, activeDraftLimitReached
    case idempotencyConflict, invalidIntent, routeConflict, corruptPersistenceState
    case invalidRoomShard, invalidInitialMembership
}

public enum V2ActorRoomBootstrapCommand: Codable, Equatable, Sendable {
    case provenDirect(V2ProvenDirectBootstrap)
    case provenDirectRecovery(V2ProvenDirectRecovery)
    case provenGroup(V2ProvenGroupBootstrap)
    public var roomID: RoomID {
        switch self {
        case .provenDirect(let v): v.roomID
        case .provenDirectRecovery(let v): v.roomID
        case .provenGroup(let v): v.placement.roomID
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

/// 已固定的待处理受众，包括控制关系是否已实体化。
