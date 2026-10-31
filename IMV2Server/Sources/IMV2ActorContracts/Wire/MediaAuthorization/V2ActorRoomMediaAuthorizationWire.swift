import Foundation
import IMV2Core

/// 仅用于房间可见性的输入。媒体控制在签发和交换时检查设备／账户权限；
/// 此处不由调用方声明这项权限。
public struct V2ActorMessageMediaVisibilityWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let mediaID: MediaID
    public let actorUserID: UserID

    public init(roomID: RoomID, messageID: MessageID, mediaID: MediaID,
                actorUserID: UserID) {
        self.roomID = roomID; self.messageID = messageID
        self.mediaID = mediaID; self.actorUserID = actorUserID
    }
}

public enum V2RoomMediaAuthorizationQuery: Codable, Equatable, Sendable {
    case messageVisibility(V2ActorMessageMediaVisibilityWire)
    case resourceUpload(V2ActorResourceUploadAuthorizationWire)
    case profileVisibilityBatch(V2ActorProfileVisibilityBatchWire)
    case profileVisibilityCohort(V2ActorProfileVisibilityCohortWire)
    case groupAvatar(V2ActorGroupAvatarVisibilityWire)
    case resourceDirectory(V2ActorRoomResourceDirectoryWire)

    public var roomID: RoomID {
        switch self {
        case .messageVisibility(let value): value.roomID
        case .resourceUpload(let value): value.roomID
        case .profileVisibilityBatch(let value): value.roomID
        case .profileVisibilityCohort(let value): value.roomID
        case .groupAvatar(let value): value.roomID
        case .resourceDirectory(let value): value.roomID
        }
    }
    public var actorUserID: UserID? {
        switch self {
        case .messageVisibility(let value): value.actorUserID
        case .resourceUpload(let value): value.actorUserID
        case .profileVisibilityBatch(let value): value.actorUserID
        case .profileVisibilityCohort: nil
        case .groupAvatar(let value): value.actorUserID
        case .resourceDirectory(let value): value.actorUserID
        }
    }
    public var retryPolicy: V2RoomReplayPolicy { .readOnly }
}

/// 用于比较签发与兑现授权读取结果的版本化房间事实。
public struct V2ActorMessageMediaVisibilitySnapshotWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let mediaID: MediaID
    public let membershipRevision: UInt64
    public let contentRevision: UInt64
    public let mediaUpdatedAt: Date
    public let uploadSessionID: UUID

    public init(roomID: RoomID, messageID: MessageID, mediaID: MediaID,
                membershipRevision: UInt64, contentRevision: UInt64,
                mediaUpdatedAt: Date, uploadSessionID: UUID) {
        self.roomID = roomID; self.messageID = messageID; self.mediaID = mediaID
        self.membershipRevision = membershipRevision
        self.contentRevision = contentRevision
        self.mediaUpdatedAt = mediaUpdatedAt
        self.uploadSessionID = uploadSessionID
    }
}

public enum V2RoomMediaAuthorizationResult: Codable, Equatable, Sendable {
    case visible(V2ActorMessageMediaVisibilitySnapshotWire)
    case resourceUploadAllowed(V2ActorResourceUploadAuthorizationSnapshotWire)
    case profilesVisible(V2ActorProfileVisibilityBatchSnapshotWire)
    case profilesVisibleCohort([V2ActorProfileVisibilityBatchSnapshotWire])
    case groupAvatarVisible(V2ActorGroupAvatarVisibilitySnapshotWire)
    case notVisible
    case resourceDirectory(V2ActorRoomResourceDirectoryPageWire)
}

/// A room-authoritative read; control/device authorization remains at the service boundary.
public struct V2ActorGroupAvatarVisibilityWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public init(roomID: RoomID, actorUserID: UserID) {
        self.roomID = roomID; self.actorUserID = actorUserID
    }
}

/// Facts contain logical identities only. No provider handles or byte capabilities cross the room lane.
public struct V2ActorGroupAvatarVisibilitySnapshotWire: Codable, Equatable, Sendable {
    public let request: V2ActorGroupAvatarVisibilityWire
    public let activation: V2RoomActivationToken
    public let membershipRevision: Int64
    public let state: V2GroupAvatarState
    public let resourceGeneration: Int64?
    public let canManage: Bool
    public let observedAt: Date
    public let activationExpiresAt: Date
    public init(request: V2ActorGroupAvatarVisibilityWire, activation: V2RoomActivationToken,
                membershipRevision: Int64, state: V2GroupAvatarState, resourceGeneration: Int64?,
                canManage: Bool, observedAt: Date, activationExpiresAt: Date) {
        self.request = request; self.activation = activation; self.membershipRevision = membershipRevision
        self.state = state; self.resourceGeneration = resourceGeneration; self.canManage = canManage
        self.observedAt = observedAt; self.activationExpiresAt = activationExpiresAt
    }
}

/// 一次房间 Actor 读取处理同一观察者的有界目标集合，不枚举完整群成员。
public struct V2ActorProfileVisibilityBatchWire: Codable, Equatable, Sendable {
    public enum RoomKind: String, Codable, Hashable, Sendable {
        case direct, group, groupJoinReview
        /// Explicit room membership; the owning Actor determines the stored kind.
        case memberRoom
    }
    public let roomID: RoomID
    public let actorUserID: UserID
    public let roomKind: RoomKind
    public let targetUserIDs: [UserID]
    public init(roomID: RoomID, actorUserID: UserID, roomKind: RoomKind, targetUserIDs: [UserID]) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.roomKind = roomKind
        self.targetUserIDs = targetUserIDs
    }

    /// Shape and work cost only; the room owner still authorizes this viewer.
    public var validatedTargetCount: Int? {
        guard roomID.uuidValue != nil, actorUserID.uuidValue != nil,
              (1...100).contains(targetUserIDs.count) else { return nil }
        let targets = targetUserIDs.compactMap(\.uuidValue)
        guard targets.count == targetUserIDs.count, Set(targets).count == targets.count else { return nil }
        return targets.count
    }
}

/// One service-authorized room invocation with independent viewer identities.
/// Both the number of viewers and their combined target work are bounded.
public struct V2ActorProfileVisibilityCohortWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let requests: [V2ActorProfileVisibilityBatchWire]
    public init(roomID: RoomID, requests: [V2ActorProfileVisibilityBatchWire]) {
        self.roomID = roomID; self.requests = requests
    }
    public var validatedTargetCount: Int? {
        guard roomID.uuidValue != nil, (1...100).contains(requests.count) else { return nil }
        var total = 0
        for request in requests {
            guard request.roomID == roomID, let count = request.validatedTargetCount,
                  count <= 100 - total else { return nil }
            total += count
        }
        return total
    }
}

/// 控制域必须复核此事实，且独立检查设备、拉黑、资料版本；它不是客户端可提交的授权。
public struct V2ActorProfileVisibilityBatchSnapshotWire: Codable, Equatable, Sendable {
    public let request: V2ActorProfileVisibilityBatchWire
    public let activation: V2RoomActivationToken
    public let membershipRevision: Int64
    public let permissionRevision: Int64
    public let visibleTargetUserIDs: [UserID]
    /// Existing nickname rows for visible group targets only; direct rooms never include them.
    public let groupMembers: [V2ActorGroupMemberPresentationWire]
    public let observedAt: Date
    public let activationExpiresAt: Date
    public init(request: V2ActorProfileVisibilityBatchWire, activation: V2RoomActivationToken,
                membershipRevision: Int64, visibleTargetUserIDs: [UserID], observedAt: Date, activationExpiresAt: Date,
                groupMembers: [V2ActorGroupMemberPresentationWire] = [], permissionRevision: Int64 = 0) {
        self.request = request; self.activation = activation; self.membershipRevision = membershipRevision
        self.visibleTargetUserIDs = visibleTargetUserIDs; self.observedAt = observedAt
        self.activationExpiresAt = activationExpiresAt
        self.groupMembers = groupMembers
        self.permissionRevision = permissionRevision
    }
}

/// 不含设备凭据；控制侧另行验证设备。上传准入不授予发送消息或设置群头像的权限。
public struct V2ActorResourceUploadAuthorizationWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let usage: V2ResourceUsage
    public init(roomID: RoomID, actorUserID: UserID, usage: V2ResourceUsage) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.usage = usage
    }
}

/// 来自一次房间执行轮次的事实，接收方必须在本地 owner 事务中复核版本与 activation。
public struct V2ActorResourceUploadAuthorizationSnapshotWire: Codable, Equatable, Sendable {
    public let request: V2ActorResourceUploadAuthorizationWire
    public let activation: V2RoomActivationToken
    public let membershipRevision: Int64
    public let permissionRevision: Int64
    public let role: String
    public let observedAt: Date
    public let activationExpiresAt: Date

    public init(request: V2ActorResourceUploadAuthorizationWire, activation: V2RoomActivationToken,
                membershipRevision: Int64, permissionRevision: Int64, role: String,
                observedAt: Date, activationExpiresAt: Date) {
        self.request = request; self.activation = activation
        self.membershipRevision = membershipRevision; self.permissionRevision = permissionRevision
        self.role = role; self.observedAt = observedAt; self.activationExpiresAt = activationExpiresAt
    }
}
