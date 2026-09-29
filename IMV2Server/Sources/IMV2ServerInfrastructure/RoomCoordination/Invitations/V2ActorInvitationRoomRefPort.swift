import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2ActorRuntime

public extension V2ActorInvitationRoomPort {
/// 服务能力携带持久化控制授权许可。普通用户操作仍须确认
/// 已认证的操作者身份，并执行房间检查。
    init(directory: V2RoomDirectory) {
        self.init(query: { query, deadline in
            let principal: V2RoomClientPrincipal
            switch query {
            case .preflightCreation, .reservedObservation, .reservedSubmissionResponse: principal = .service
            case .active, .pending, .resolvedPreview: principal = .user(query.actorUserID)
            }
            return try await v2InvitationResponse(directory.room(query.roomID).call(
                .invitationQuery(query), principal: principal, deadline: deadline))
        })
    }
}

private func v2InvitationResponse(_ response: V2RoomResponse) throws -> V2RoomInvitationResult {
    guard case .invitation(let value) = response else { throw V2RoomCallFailure.outcomeUnknown }
    guard case .failure(let failure) = value else { return value }
    switch failure {
    case .invalidSecret, .invalidLink, .invalidPreview, .invalidGroupJoinRequest:
        throw try failure.toValidationError()
    case .directoryConflict, .ownerResultMismatch:
        throw try failure.toDirectoryError()
    default:
        throw try failure.toServiceError()
    }
}
