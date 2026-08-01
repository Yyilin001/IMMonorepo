import Foundation

/// Immutable client intent for one personal conversation projection.  The
/// operation ID is the retry key; timestamps are server facts and therefore
/// deliberately absent from the command.
public struct V2ConversationStateCommand: Equatable, Sendable {
    public let operationID: ConversationPreferenceOperationID
    public let roomID: RoomID
    public let isPinned: Bool
    public let isArchived: Bool
    public let muteUntil: Date?

    public init(operationID: ConversationPreferenceOperationID, roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?) throws {
        if let muteUntil, muteUntil <= .distantPast { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID
        self.roomID = roomID
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
    }
}

public struct V2MessageFavoriteCommand: Equatable, Sendable {
    public let operationID: MessageFavoriteOperationID
    public let roomID: RoomID
    public let messageID: MessageID
    public let isFavorited: Bool

    public init(operationID: MessageFavoriteOperationID, roomID: RoomID, messageID: MessageID, isFavorited: Bool) {
        self.operationID = operationID; self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited
    }
}

public struct V2ConversationState: Equatable, Sendable {
    public let roomID: RoomID; public let isPinned: Bool; public let isArchived: Bool; public let muteUntil: Date?; public let updatedAt: Date
    public init(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?, updatedAt: Date) { self.roomID = roomID; self.isPinned = isPinned; self.isArchived = isArchived; self.muteUntil = muteUntil; self.updatedAt = updatedAt }
}

public struct V2MessageFavorite: Equatable, Sendable {
    public let roomID: RoomID; public let messageID: MessageID; public let isFavorited: Bool; public let updatedAt: Date
    public init(roomID: RoomID, messageID: MessageID, isFavorited: Bool, updatedAt: Date) { self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited; self.updatedAt = updatedAt }
}

/// A forward is bounded before it reaches persistence. Each source/target
/// pair gets an independent durable outcome, so retrying an operation never
/// duplicates already accepted output.
public struct V2ForwardMessagesCommand: Equatable, Sendable {
    public static let maximumSourceMessages = 100
    public static let maximumTargetRooms = 10
    public let operationID: MessageForwardOperationID
    public let sourceMessageIDs: [MessageID]
    public let targetRoomIDs: [RoomID]

    public init(operationID: MessageForwardOperationID, sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID]) throws {
        guard !sourceMessageIDs.isEmpty, sourceMessageIDs.count <= Self.maximumSourceMessages,
              !targetRoomIDs.isEmpty, targetRoomIDs.count <= Self.maximumTargetRooms,
              Set(sourceMessageIDs).count == sourceMessageIDs.count,
              Set(targetRoomIDs).count == targetRoomIDs.count
        else { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID; self.sourceMessageIDs = sourceMessageIDs; self.targetRoomIDs = targetRoomIDs
    }
}

public struct V2ForwardMessageResult: Equatable, Sendable {
    public let sourceMessageID: MessageID
    public let targetRoomID: RoomID
    public let messageID: MessageID?
    public let roomSequence: UInt64?
    public let errorCode: String?

    public init(sourceMessageID: MessageID, targetRoomID: RoomID, messageID: MessageID?, roomSequence: UInt64?, errorCode: String?) {
        precondition((messageID != nil && roomSequence != nil && errorCode == nil) || (messageID == nil && roomSequence == nil && errorCode != nil))
        self.sourceMessageID = sourceMessageID; self.targetRoomID = targetRoomID; self.messageID = messageID; self.roomSequence = roomSequence; self.errorCode = errorCode
    }
}
