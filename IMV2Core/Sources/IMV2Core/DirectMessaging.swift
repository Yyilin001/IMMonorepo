import Foundation

/// The recipient-owned privacy control for new messages from users who are
/// neither friends nor already in a mutually replied direct conversation.
public enum V2StrangerMessagePermission: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

/// Opens (or returns) the unique direct room for two distinct users. The
/// operation ID is durable client intent and therefore survives reconnects.
public struct V2OpenDirectRoomCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: DirectRoomOperationID
    public let targetUserID: UserID

    public init(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) throws {
        guard actorUserID != targetUserID else { throw V2DirectMessagingValidationError.selfTargetingNotAllowed }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
    }
}

/// A device-independent setting. It is owned by the authenticated user, not
/// by a particular direct room or device.
public struct V2SetStrangerMessagePermissionCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: StrangerMessagePreferenceOperationID
    public let permission: V2StrangerMessagePermission

    public init(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.permission = permission
    }
}

public struct V2DirectRoom: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let createdAt: Date

    public init(roomID: RoomID, actorUserID: UserID, targetUserID: UserID, createdAt: Date) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.createdAt = createdAt
    }
}

public enum V2DirectMessagingValidationError: Error, Equatable, Sendable {
    case selfTargetingNotAllowed
}
