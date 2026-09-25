import Foundation
import IMV2ActorContracts
import IMV2Core

/// 账户 HTTP 的领域契约。旧服务与基于 Actor 的控制域协调者
/// 保持相同的公开邀请结果。
public protocol V2GroupInvitationHandling: Sendable {
    func create(_ request: V2CreateGroupInviteRequest) async throws -> V2GroupInviteLink
    func activeInvites(roomID: RoomID, actorUserID: UserID) async throws -> [V2GroupInviteLink]
    func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID,
                operationID: GroupInviteOperationID) async throws
    func preview(secret: V2GroupInviteSecret, applicantUserID: UserID) async throws -> V2GroupInvitePreview?
    func submit(_ request: V2SubmitGroupJoinRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome
    func pendingRequests(roomID: RoomID, reviewerUserID: UserID,
                         cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage
    func cancel(roomID: RoomID, requestID: GroupJoinRequestID,
                applicantUserID: UserID) async throws -> V2GroupJoinRequest
    func decide(_ input: V2DecideGroupJoinRequest) async throws -> V2GroupJoinDecisionOutcome
}

extension V2GroupInvitationService: V2GroupInvitationHandling {}

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

    public func create(_ request: V2CreateGroupInviteRequest) async throws -> V2GroupInviteLink {
        let wire = V2ActorCreateGroupInviteWire(roomID: request.roomID,
            actorUserID: request.actorUserID, operationID: request.operationID,
            lifetime: request.lifetime, maximumApprovedUses: request.maximumApprovedUses)
        guard case .created(let link) = try await coordinator.create(wire, deadline: deadline()) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        let value = try link.toDomain()
        guard value.roomID == request.roomID else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return value
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

    public func revoke(inviteID: GroupInviteID, roomID: RoomID,
                       actorUserID: UserID, operationID: GroupInviteOperationID) async throws {
        guard case .revoked = try await coordinator.revoke(.init(roomID: roomID,
            actorUserID: actorUserID, operationID: operationID, inviteID: inviteID),
            deadline: deadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
    }

    public func preview(secret: V2GroupInviteSecret,
                        applicantUserID: UserID) async throws -> V2GroupInvitePreview? {
        guard case .preview(let value) = try await coordinator.previewBySecret(
            .init(applicantUserID: applicantUserID, secret: .init(domain: secret)),
            deadline: deadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return try value?.toDomain()
    }

    public func submit(_ request: V2SubmitGroupJoinRequest) async throws -> V2GroupJoinSubmissionPersistenceOutcome {
        guard case .submission(let value) = try await coordinator.submitBySecret(
            .init(applicantUserID: request.applicantUserID, operationID: request.operationID,
                  secret: .init(domain: request.secret), note: request.note),
            deadline: deadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        return try value.toDomain()
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

    public func cancel(roomID: RoomID, requestID: GroupJoinRequestID,
                       applicantUserID: UserID) async throws -> V2GroupJoinRequest {
        guard case .cancelled(let value) = try await coordinator.cancel(
            .init(roomID: roomID, requestID: requestID, applicantUserID: applicantUserID),
            deadline: deadline()) else { throw V2GroupInviteDirectoryError.ownerResultMismatch }
        let result = try value.toDomain()
        guard result.roomID == roomID, result.requestID == requestID,
              result.applicant.userID == applicantUserID else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        return result
    }

    public func decide(_ input: V2DecideGroupJoinRequest) async throws -> V2GroupJoinDecisionOutcome {
        guard case .decided(let value) = try await coordinator.decide(
            .init(roomID: input.roomID, requestID: input.requestID,
                  reviewerUserID: input.reviewerUserID, operationID: input.operationID,
                  decision: input.decision), deadline: deadline()) else {
            throw V2GroupInviteDirectoryError.ownerResultMismatch
        }
        let outcome = try value.toDomain()
        switch outcome {
        case .approved(let record), .rejected(let record), .alreadyDecided(let record):
            guard record.roomID == input.roomID, record.requestID == input.requestID else {
                throw V2GroupInviteDirectoryError.ownerResultMismatch
            }
        default: break
        }
        return outcome
    }
}
