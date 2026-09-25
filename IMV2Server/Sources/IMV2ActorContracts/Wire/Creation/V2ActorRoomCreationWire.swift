import Foundation
import IMV2Core

/// 房间创建前的入口。生成的 ID、放置位置、时钟和容量策略由协调者负责。
public struct V2ActorOpenDirectRoomWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: DirectRoomOperationID
    public let targetUserID: UserID
    public init(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.targetUserID = targetUserID
    }
}

public struct V2ActorCreateGroupRoomWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let initialMemberUserIDs: [UserID]
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String, initialMemberUserIDs: [UserID]) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.title = title
        self.initialMemberUserIDs = initialMemberUserIDs
    }
}

public struct V2ActorStagedGroupBeginWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.title = title
    }
}

public struct V2ActorStagedGroupAppendWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let memberUserIDs: [UserID]
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, memberUserIDs: [UserID]) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.memberUserIDs = memberUserIDs
    }
}

public struct V2ActorStagedGroupOperationWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public init(actorUserID: UserID, operationID: GroupRoomOperationID) {
        self.actorUserID = actorUserID; self.operationID = operationID
    }
}

public enum V2ActorRoomCreationCommand: Codable, Equatable, Sendable {
    case openDirect(V2ActorOpenDirectRoomWire)
    case createGroup(V2ActorCreateGroupRoomWire)
    case beginStaged(V2ActorStagedGroupBeginWire)
    case appendStaged(V2ActorStagedGroupAppendWire)
    case finalizeStaged(V2ActorStagedGroupOperationWire)
    case cancelStaged(V2ActorStagedGroupOperationWire)

    public var actorUserID: UserID {
        switch self {
        case .openDirect(let v): v.actorUserID
        case .createGroup(let v): v.actorUserID
        case .beginStaged(let v): v.actorUserID
        case .appendStaged(let v): v.actorUserID
        case .finalizeStaged(let v): v.actorUserID
        case .cancelStaged(let v): v.actorUserID
        }
    }
    public var stableOperationIdentity: V2ActorRoomCreationOperationIdentity {
        switch self {
        case .openDirect(let v): .direct(v.operationID)
        case .createGroup(let v): .group(v.operationID)
        case .beginStaged(let v): .group(v.operationID)
        case .appendStaged(let v): .group(v.operationID)
        case .finalizeStaged(let v): .group(v.operationID)
        case .cancelStaged(let v): .group(v.operationID)
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

public enum V2ActorRoomCreationOperationIdentity: Equatable, Sendable {
    case direct(DirectRoomOperationID)
    case group(GroupRoomOperationID)
}

public struct V2ActorDirectRoomWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let createdAt: Date
    public init(roomID: RoomID, actorUserID: UserID, targetUserID: UserID, createdAt: Date) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.targetUserID = targetUserID; self.createdAt = createdAt
    }
}

public struct V2ActorGroupRoomWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let ownerUserID: UserID
    public let title: String
    public let capacityClass: V2GroupCapacityClass
    public let memberCount: Int
    public let memberUserIDs: [UserID]
    public let createdAt: Date
    public init(roomID: RoomID, ownerUserID: UserID, title: String, capacityClass: V2GroupCapacityClass, memberCount: Int, memberUserIDs: [UserID], createdAt: Date) {
        self.roomID = roomID; self.ownerUserID = ownerUserID; self.title = title; self.capacityClass = capacityClass
        self.memberCount = memberCount; self.memberUserIDs = memberUserIDs; self.createdAt = createdAt
    }
}

public struct V2ActorStagedGroupDraftWire: Codable, Equatable, Sendable {
    public let operationID: GroupRoomOperationID
    public let title: String
    public let stagedMemberCount: Int
    public init(operationID: GroupRoomOperationID, title: String, stagedMemberCount: Int) {
        self.operationID = operationID; self.title = title; self.stagedMemberCount = stagedMemberCount
    }
}

public enum V2ActorOpenDirectRoomOutcomeWire: Codable, Equatable, Sendable {
    case opened(V2ActorDirectRoomWire)
    case idempotent(V2ActorDirectRoomWire)
    case idempotencyConflict
    case unavailable
}
public enum V2ActorCreateGroupRoomOutcomeWire: Codable, Equatable, Sendable {
    case created(V2ActorGroupRoomWire)
    case idempotent(V2ActorGroupRoomWire)
    case idempotencyConflict
    case invalidMembers
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
}
public enum V2ActorRoomCreationResult: Codable, Equatable, Sendable {
    case direct(V2ActorOpenDirectRoomOutcomeWire)
    case group(V2ActorCreateGroupRoomOutcomeWire)
    case draft(V2ActorStagedGroupDraftWire)
    case cancelled
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
public enum V2ActorPrepareGroupCreationIntentResultWire: Codable, Equatable, Sendable {
    case prepared(V2ActorGroupCreationIntentWire)
    case idempotent(V2ActorGroupCreationIntentWire)
    case idempotencyConflict
    case invalidMembers
}
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

/// 协调者发往所有者的内部引导操作；放置位置和 ID 在派发前固定。
public struct V2ActorDirectBootstrapWire: Codable, Equatable, Sendable {
    public let command: V2ActorOpenDirectRoomWire
    public let roomID: RoomID
    public let roomShardID: String
    public init(command: V2ActorOpenDirectRoomWire, roomID: RoomID, roomShardID: String) {
        self.command = command; self.roomID = roomID; self.roomShardID = roomShardID
    }
}
public struct V2ActorGroupBootstrapWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let capacityClass: V2GroupCapacityClass
    public let initialMemberUserIDs: [UserID]
    public let validatedMemberUserIDs: [UserID]
    public let intent: V2ActorGroupCreationIntentWire
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String,
                capacityClass: V2GroupCapacityClass, initialMemberUserIDs: [UserID],
                validatedMemberUserIDs: [UserID], intent: V2ActorGroupCreationIntentWire) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.title = title
        self.capacityClass = capacityClass; self.initialMemberUserIDs = initialMemberUserIDs
        self.validatedMemberUserIDs = validatedMemberUserIDs; self.intent = intent
    }
}
public struct V2ActorStagedGroupBootstrapWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let capacityClass: V2GroupCapacityClass
    public let stagedMemberCount: Int
    public let intent: V2ActorGroupCreationIntentWire
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String,
                capacityClass: V2GroupCapacityClass, stagedMemberCount: Int,
                intent: V2ActorGroupCreationIntentWire) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.title = title
        self.capacityClass = capacityClass; self.stagedMemberCount = stagedMemberCount; self.intent = intent
    }
}
public enum V2ActorRoomBootstrapCommand: Codable, Equatable, Sendable {
    case direct(V2ActorDirectBootstrapWire)
    case group(V2ActorGroupBootstrapWire)
    case stagedGroup(V2ActorStagedGroupBootstrapWire)
    public var roomID: RoomID {
        switch self {
        case .direct(let v): v.roomID
        case .group(let v): v.intent.roomID
        case .stagedGroup(let v): v.intent.roomID
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

/// 已固定的待处理受众，包括控制关系是否已实体化。
public struct V2ActorGroupAudienceImportWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let memberUserIDs: [UserID]
    public let stagedMemberCount: Int
    public let hasMaterializedMembers: Bool
    public init(actorUserID: UserID, operationID: GroupRoomOperationID, title: String,
                memberUserIDs: [UserID], stagedMemberCount: Int, hasMaterializedMembers: Bool) {
        self.actorUserID = actorUserID; self.operationID = operationID; self.title = title
        self.memberUserIDs = memberUserIDs; self.stagedMemberCount = stagedMemberCount
        self.hasMaterializedMembers = hasMaterializedMembers
    }
}
