import Foundation

/// Controls whether a user's short-lived activity facts may be disclosed.
/// These settings never change receipt collection or message delivery.
public struct V2LiveActivityPreferences: Equatable, Sendable {
    public let allowsOnlinePresence: Bool
    public let allowsTypingIndicators: Bool
    public let updatedAt: Date

    public init(allowsOnlinePresence: Bool, allowsTypingIndicators: Bool, updatedAt: Date) {
        self.allowsOnlinePresence = allowsOnlinePresence
        self.allowsTypingIndicators = allowsTypingIndicators
        self.updatedAt = updatedAt
    }
}

public struct V2SetLiveActivityPreferencesCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: LiveActivityPreferenceOperationID
    public let allowsOnlinePresence: Bool
    public let allowsTypingIndicators: Bool

    public init(actorUserID: UserID, operationID: LiveActivityPreferenceOperationID, allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.allowsOnlinePresence = allowsOnlinePresence
        self.allowsTypingIndicators = allowsTypingIndicators
    }
}

/// A display-only, lease-backed online fact. `expiresAt` is a hard client
/// boundary: after it passes, callers must render offline even before a later
/// socket event arrives.
public struct V2PresenceState: Equatable, Sendable {
    public let roomID: RoomID
    public let targetUserID: UserID
    public let isOnline: Bool
    public let expiresAt: Date

    public init(roomID: RoomID, targetUserID: UserID, isOnline: Bool, expiresAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.isOnline = isOnline
        self.expiresAt = expiresAt
    }
}

public struct V2TypingState: Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let isTyping: Bool
    public let expiresAt: Date

    public init(roomID: RoomID, userID: UserID, isTyping: Bool, expiresAt: Date) {
        self.roomID = roomID
        self.userID = userID
        self.isTyping = isTyping
        self.expiresAt = expiresAt
    }
}
