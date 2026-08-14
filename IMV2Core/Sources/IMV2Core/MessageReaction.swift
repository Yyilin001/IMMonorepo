import Foundation

/// A reaction is a concurrent set member, keyed by
/// `(message_id, actor_user_id, reaction)`.  It deliberately does not share
/// a message-content revision: independent actors may add or remove distinct
/// reactions without overwriting each other.
public enum V2MessageReactionAction: String, Codable, Equatable, Sendable {
    case add
    case remove
}

/// Reaction state must remain bounded independently of room membership. The
/// palette bound prevents one actor from manufacturing an arbitrary number of
/// distinct set members, while the message bound protects every fan-out and
/// snapshot recipient from an unbounded popular-message projection.
public enum V2MessageReactionLimits {
    public static let maximumReactionBytes = 16
    public static let maximumReactionsPerActorPerMessage = 8
    public static let maximumReactionsPerMessage = 1_024
}

public struct V2ChangeMessageReactionCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageReactionOperationID
    public let messageID: MessageID
    public let reaction: String
    public let action: V2MessageReactionAction

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) throws {
        let normalized = reaction.precomposedStringWithCanonicalMapping
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= V2MessageReactionLimits.maximumReactionBytes,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw V2MessageReactionValidationError.invalidReaction }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.reaction = normalized
        self.action = action
    }
}

public struct V2MessageReactionChange: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let actorUserID: UserID
    public let reaction: String
    public let action: V2MessageReactionAction
    public let roomSequence: UInt64
    public let eventID: EventID
    public let fanoutPlanID: FanoutPlanID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID, reaction: String, action: V2MessageReactionAction, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.actorUserID = actorUserID
        self.reaction = reaction
        self.action = action
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

public enum V2MessageReactionValidationError: Error, Equatable, Sendable {
    case invalidReaction
}
