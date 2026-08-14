import Foundation
import IMV2Core

public protocol V2ProfilePresentationManaging: Sendable {
    func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage
    func updateContactAlias(ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID, expectedRevision: V2ProfileRevision?, remarkName: String?) async throws -> V2ContactAlias
    func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage
    func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?, nickname: String?) async throws -> V2GroupMemberPresentation
}

public struct V2ContactAliasPage: Equatable, Sendable {
    public let values: [V2ContactAlias]
    public let nextCursor: UserID?
    public init(values: [V2ContactAlias], nextCursor: UserID?) {
        self.values = values
        self.nextCursor = nextCursor
    }
}

public struct V2GroupNicknamePage: Equatable, Sendable {
    public let values: [V2GroupMemberPresentation]
    public let nextCursor: UserID?
    public init(values: [V2GroupMemberPresentation], nextCursor: UserID?) {
        self.values = values
        self.nextCursor = nextCursor
    }
}

public enum V2ProfilePresentationError: Error, Equatable, Sendable {
    case unavailable
    case forbidden
    case revisionConflict(V2ProfileRevision?)
    case operationPayloadMismatch
    case invalidPresentation
    case corruptPersistenceState
}
