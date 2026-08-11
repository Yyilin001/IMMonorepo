import Foundation
import IMV2Core

public protocol V2ProfilePresentationManaging: Sendable {
    func contactAliases(ownerUserID: UserID) async throws -> [V2ContactAlias]
    func updateContactAlias(ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID, expectedRevision: V2ProfileRevision?, remarkName: String?) async throws -> V2ContactAlias
    func groupNicknames(actorUserID: UserID, roomID: RoomID) async throws -> [V2GroupMemberPresentation]
    func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?, nickname: String?) async throws -> V2GroupMemberPresentation
}

public enum V2ProfilePresentationError: Error, Equatable, Sendable {
    case unavailable
    case forbidden
    case revisionConflict(V2ProfileRevision?)
    case operationPayloadMismatch
    case invalidPresentation
    case corruptPersistenceState
}
