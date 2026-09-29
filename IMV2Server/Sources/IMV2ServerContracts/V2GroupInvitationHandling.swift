import IMV2Core

/// 账户 HTTP 的领域契约。旧服务与基于 Actor 的控制域协调者
/// 保持相同的公开邀请结果。
public protocol V2GroupInvitationHandling: Sendable {
    func activeInvites(roomID: RoomID, actorUserID: UserID) async throws -> [V2GroupInviteLink]
    func preview(secret: V2GroupInviteSecret, applicantUserID: UserID) async throws -> V2GroupInvitePreview?
    func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage
}
