import Foundation
import IMV2ActorContracts
import IMV2Core

/// 账户 HTTP 的领域契约。旧服务与基于 Actor 的控制域协调者
/// 保持相同的公开邀请结果。
public protocol V2GroupInvitationHandling: Sendable {
    func activeInvites(roomID:RoomID,actorUserID:UserID) async throws -> [V2GroupInviteLink]
    func preview(secret:V2GroupInviteSecret,applicantUserID:UserID) async throws -> V2GroupInvitePreview?
    func pendingRequests(roomID:RoomID,reviewerUserID:UserID,cursor:String?,pageSize:Int) async throws -> V2GroupJoinRequestPage
}

/// 未知房间的令牌与额度处理留在控制域协调者；
/// 每项归属房间的预检、修改和查询都使用对应的 RoomRef 端口。
public struct V2ActorGroupInvitationClient: V2GroupInvitationHandling {
    private let coordinator: V2ActorInvitationCoordinator
    private let callTimeout: Duration

    public init(coordinator: V2ActorInvitationCoordinator,
                callTimeout: Duration = .seconds(10)) {
        precondition(callTimeout > .zero)
        self.coordinator = coordinator
        self.callTimeout = callTimeout
    }

    private func deadline() throws -> ContinuousClock.Instant {
        try Task.checkCancellation()
        return ContinuousClock.now.advanced(by: callTimeout)
    }



    public func activeInvites(roomID: RoomID, actorUserID: UserID) async throws -> [V2GroupInviteLink] {
        guard case .active(let links) = try await coordinator.active(.init(roomID: roomID,
            actorUserID: actorUserID), deadline: deadline()) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return try links.map { link in
            let value = try link.toDomain()
            guard value.roomID == roomID else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
            return value
        }
    }



    public func preview(secret: V2GroupInviteSecret,
                        applicantUserID: UserID) async throws -> V2GroupInvitePreview? {
        guard case .preview(let value) = try await coordinator.previewBySecret(
            .init(applicantUserID: applicantUserID, secret: .init(domain: secret)),
            deadline: deadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return try value?.toDomain()
    }



    public func pendingRequests(roomID: RoomID, reviewerUserID: UserID,
                                cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage {
        guard case .pending(let value) = try await coordinator.pending(
            .init(roomID: roomID, reviewerUserID: reviewerUserID,
                  cursor: cursor, pageSize: pageSize), deadline: deadline()) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        let page = try value.toDomain()
        guard page.requests.allSatisfy({ $0.roomID == roomID }) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return page
    }




}
