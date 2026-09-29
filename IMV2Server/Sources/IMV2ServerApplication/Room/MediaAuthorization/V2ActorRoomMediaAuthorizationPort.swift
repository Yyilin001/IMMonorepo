import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 媒体控制在授权签发和服务商交换时都使用此端口。
/// 设备权限与服务商字节数据仍由控制域协调者负责。
public struct V2ActorRoomMediaAuthorizationPort: Sendable {
    private let query: @Sendable (V2RoomMediaAuthorizationQuery, ContinuousClock.Instant) async throws -> V2RoomMediaAuthorizationResult

    public init(query: @escaping @Sendable (V2RoomMediaAuthorizationQuery, ContinuousClock.Instant) async throws -> V2RoomMediaAuthorizationResult) {
        self.query = query
    }

    public func capture(_ request: V2ActorMessageMediaVisibilityWire,
                        deadline: ContinuousClock.Instant) async throws -> V2ActorMessageMediaVisibilitySnapshotWire? {
        switch try await query(.messageVisibility(request), deadline) {
        case .visible(let snapshot):
            guard snapshot.roomID == request.roomID,
                  snapshot.messageID == request.messageID,
                  snapshot.mediaID == request.mediaID,
                  snapshot.membershipRevision <= UInt64(Int64.max),
                  snapshot.contentRevision > 0,
                  snapshot.contentRevision <= UInt64(Int64.max),
                  snapshot.mediaUpdatedAt.timeIntervalSince1970.isFinite else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            return snapshot
        case .notVisible: return nil
        case .resourceUploadAllowed, .profilesVisible, .groupAvatarVisible: throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func captureUpload(_ request: V2ActorResourceUploadAuthorizationWire,
                              deadline: ContinuousClock.Instant) async throws -> V2ActorResourceUploadAuthorizationSnapshotWire? {
        switch try await query(.resourceUpload(request), deadline) {
        case .resourceUploadAllowed(let snapshot):
            guard snapshot.request == request, snapshot.activation.roomID == request.roomID,
                  request.usage.home(actorUserID: request.actorUserID) == .room(request.roomID),
                  snapshot.membershipRevision >= 0, snapshot.permissionRevision > 0,
                  V2RoomMembershipRole(rawValue: snapshot.role) != nil,
                  snapshot.observedAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt > snapshot.observedAt
            else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return snapshot
        case .notVisible: return nil
        case .visible, .profilesVisible, .groupAvatarVisible: throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func captureProfiles(_ request: V2ActorProfileVisibilityBatchWire,
                                deadline: ContinuousClock.Instant) async throws -> V2ActorProfileVisibilityBatchSnapshotWire? {
        guard !request.targetUserIDs.isEmpty, request.targetUserIDs.count <= 100,
              Set(request.targetUserIDs).count == request.targetUserIDs.count
        else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        switch try await query(.profileVisibilityBatch(request), deadline) {
        case .profilesVisible(let snapshot):
            guard snapshot.request == request, snapshot.activation.roomID == request.roomID,
                  snapshot.membershipRevision >= 0, snapshot.permissionRevision >= 0,
                  Set(snapshot.visibleTargetUserIDs).count == snapshot.visibleTargetUserIDs.count,
                  Set(snapshot.visibleTargetUserIDs).isSubset(of: Set(request.targetUserIDs)),
                  snapshot.groupMembers.count <= snapshot.visibleTargetUserIDs.count,
                  Set(snapshot.groupMembers.map(\.userID)).count == snapshot.groupMembers.count,
                  snapshot.groupMembers.allSatisfy({ member in
                      (request.roomKind == .group || request.roomKind == .memberRoom) && member.roomID == request.roomID
                        && snapshot.visibleTargetUserIDs.contains(member.userID) && (try? member.domain()) != nil
                  }),
                  snapshot.observedAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt > snapshot.observedAt
            else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return snapshot
        case .notVisible: return nil
        case .visible, .resourceUploadAllowed, .groupAvatarVisible: throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func captureGroupAvatar(_ request: V2ActorGroupAvatarVisibilityWire,
                                   deadline: ContinuousClock.Instant) async throws -> V2ActorGroupAvatarVisibilitySnapshotWire? {
        guard request.roomID.uuidValue != nil, request.actorUserID.uuidValue != nil else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        switch try await query(.groupAvatar(request), deadline) {
        case .groupAvatarVisible(let snapshot):
            guard snapshot.request == request, snapshot.activation.roomID == request.roomID,
                  snapshot.state.roomID == request.roomID, snapshot.membershipRevision >= 0,
                  (snapshot.state.mediaID == nil && snapshot.resourceGeneration == nil)
                    || (snapshot.state.mediaID != nil && (snapshot.resourceGeneration ?? 0) > 0),
                  snapshot.observedAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt.timeIntervalSince1970.isFinite,
                  snapshot.activationExpiresAt > snapshot.observedAt
            else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            return snapshot
        case .notVisible: return nil
        case .visible, .resourceUploadAllowed, .profilesVisible:
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
    }

    public func recheckGroupAvatar(_ snapshot: V2ActorGroupAvatarVisibilitySnapshotWire,
                                   deadline: ContinuousClock.Instant) async throws -> Bool {
        guard let latest = try await captureGroupAvatar(snapshot.request, deadline: deadline) else { return false }
        return latest.activation == snapshot.activation && latest.membershipRevision == snapshot.membershipRevision
            && latest.state == snapshot.state && latest.resourceGeneration == snapshot.resourceGeneration
            && latest.canManage == snapshot.canManage
    }

    public func recheckProfiles(_ snapshot: V2ActorProfileVisibilityBatchSnapshotWire,
                                deadline: ContinuousClock.Instant) async throws -> Bool {
        guard let latest = try await captureProfiles(snapshot.request, deadline: deadline) else { return false }
        return latest.activation == snapshot.activation && latest.membershipRevision == snapshot.membershipRevision
            && latest.permissionRevision == snapshot.permissionRevision
            && Set(latest.visibleTargetUserIDs) == Set(snapshot.visibleTargetUserIDs)
            && latest.groupMembers.sorted { $0.userID.rawValue < $1.userID.rawValue }
                == snapshot.groupMembers.sorted { $0.userID.rawValue < $1.userID.rawValue }
    }

    /// 已存储的授权不能代替新的房间执行轮次。成员、内容或媒体代次
    /// 发生任何变化，都会使先前的快照失效。
    public func recheck(_ snapshot: V2ActorMessageMediaVisibilitySnapshotWire,
                        actorUserID: UserID,
                        deadline: ContinuousClock.Instant) async throws -> Bool {
        let request = V2ActorMessageMediaVisibilityWire(roomID: snapshot.roomID,
            messageID: snapshot.messageID, mediaID: snapshot.mediaID,
            actorUserID: actorUserID)
        return try await capture(request, deadline: deadline) == snapshot
    }
}
