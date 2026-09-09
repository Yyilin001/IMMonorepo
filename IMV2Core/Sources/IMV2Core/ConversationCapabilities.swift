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
        if let muteUntil {
            guard let milliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
                  milliseconds > 0
            else { throw V2CoreError.invalidPositiveValue }
        }
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

/// A selected source is located by its room and fenced at the version the
/// user saw. Retries must never look up a newer version and change the intent.
public struct V2ForwardMessageReference: Equatable, Hashable, Codable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let revision: V2MessageRevision

    public init(roomID: RoomID, messageID: MessageID, revision: V2MessageRevision) {
        self.roomID = roomID
        self.messageID = messageID
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case roomID, messageID, revision }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(roomID: try .init(values.decode(String.self, forKey: .roomID)),
                  messageID: try .init(values.decode(String.self, forKey: .messageID)),
                  revision: try .init(values.decode(UInt64.self, forKey: .revision)))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roomID.rawValue, forKey: .roomID)
        try values.encode(messageID.rawValue, forKey: .messageID)
        try values.encode(revision.rawValue, forKey: .revision)
    }
}

/// Each source/target pair gets an independent durable outcome. Source
/// identity is unique even if an input claims two rooms for the same message.
public struct V2ForwardMessagesCommand: Equatable, Sendable {
    public static let maximumSourceMessages = 100
    public static let maximumTargetRooms = 10
    public let operationID: MessageForwardOperationID
    public let sources: [V2ForwardMessageReference]
    public let targetRoomIDs: [RoomID]
    public var sourceMessageIDs: [MessageID] { sources.map(\.messageID) }

    public init(operationID: MessageForwardOperationID, sources: [V2ForwardMessageReference], targetRoomIDs: [RoomID]) throws {
        guard !sources.isEmpty, sources.count <= Self.maximumSourceMessages,
              !targetRoomIDs.isEmpty, targetRoomIDs.count <= Self.maximumTargetRooms,
              Set(sources.map(\.messageID)).count == sources.count,
              Set(targetRoomIDs).count == targetRoomIDs.count
        else { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID
        self.sources = sources
        self.targetRoomIDs = targetRoomIDs
    }
}

public struct V2ForwardMessageResult: Equatable, Sendable {
    public let sourceMessageID: MessageID
    public let targetRoomID: RoomID
    public let messageID: MessageID?
    public let roomSequence: UInt64?
    public let errorCode: String?

    public init(sourceMessageID: MessageID, targetRoomID: RoomID, messageID: MessageID?, roomSequence: UInt64?, errorCode: String?) throws {
        guard (messageID != nil && roomSequence != nil && errorCode == nil) || (messageID == nil && roomSequence == nil && errorCode != nil) else {
            throw V2ForwardMessageResultValidationError.invalidShape
        }
        if let roomSequence, roomSequence == 0 || roomSequence > UInt64(Int64.max) {
            throw V2ForwardMessageResultValidationError.invalidSequence
        }
        self.sourceMessageID = sourceMessageID; self.targetRoomID = targetRoomID; self.messageID = messageID; self.roomSequence = roomSequence; self.errorCode = errorCode
    }
}

public enum V2ForwardMessageResultValidationError: Error, Equatable, Sendable {
    case invalidShape
    case invalidSequence
}
