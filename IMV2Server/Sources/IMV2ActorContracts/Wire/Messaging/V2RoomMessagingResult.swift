import Foundation
import IMV2Core

public enum V2ActorDirectMessageDeniedReasonWire: String, Codable, Equatable, Sendable {
    case generic
    case systemAccountReadOnly = "system_account_read_only"
}

public struct V2ActorAcceptedMessageWire: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mediaPresentations: [V2MediaPresentation]
    public let mentions: [V2ActorMentionTargetWire]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let groupCapacityClass: V2GroupCapacityClass?
    public let sourceEventID: EventID?
    public let acceptedMembershipRevision: UInt64?
    public let directRecipientUserID: UserID?
    public let projectionCreatedAtUnixMilliseconds: Int64?
    public let createdAt: Date

    public init(messageID: MessageID, roomID: RoomID, roomSequence: UInt64, timelineSequence: UInt64, senderUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mediaPresentations: [V2MediaPresentation], mentions: [V2ActorMentionTargetWire], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, groupCapacityClass: V2GroupCapacityClass?, sourceEventID: EventID?, acceptedMembershipRevision: UInt64?, directRecipientUserID: UserID?, projectionCreatedAtUnixMilliseconds: Int64?, createdAt: Date) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.groupCapacityClass = groupCapacityClass
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.projectionCreatedAtUnixMilliseconds = projectionCreatedAtUnixMilliseconds
        self.createdAt = createdAt
    }
}

public struct V2ActorMessageAcceptanceReceiptWire: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let groupCapacityClass: V2GroupCapacityClass?
    public let sourceEventID: EventID?
    public let acceptedMembershipRevision: UInt64?
    public let directRecipientUserID: UserID?
    public let createdAt: Date

    public init(messageID: MessageID, roomID: RoomID, roomSequence: UInt64, timelineSequence: UInt64, senderUserID: UserID, clientMessageID: ClientMessageID, groupCapacityClass: V2GroupCapacityClass?, sourceEventID: EventID?, acceptedMembershipRevision: UInt64?, directRecipientUserID: UserID?, createdAt: Date) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.groupCapacityClass = groupCapacityClass
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.createdAt = createdAt
    }
}

public struct V2ActorDirectMessageDeniedWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let sourceEventID: EventID
    public let timelineSequence: UInt64
    public let createdAt: Date
    public let reason: V2ActorDirectMessageDeniedReasonWire

    public init(roomID: RoomID, sourceEventID: EventID, timelineSequence: UInt64, createdAt: Date, reason: V2ActorDirectMessageDeniedReasonWire) {
        self.roomID = roomID
        self.sourceEventID = sourceEventID
        self.timelineSequence = timelineSequence
        self.createdAt = createdAt
        self.reason = reason
    }
}

public struct V2ActorMessageEditWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let text: String
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, text: String, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.text = text
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}

public struct V2ActorMessageWithdrawalWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}

public struct V2ActorMessageReactionChangeWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let actorUserID: UserID
    public let reaction: String
    public let action: V2MessageReactionAction
    public let roomSequence: UInt64
    public let eventID: EventID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID, reaction: String, action: V2MessageReactionAction, roomSequence: UInt64, eventID: EventID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.actorUserID = actorUserID
        self.reaction = reaction
        self.action = action
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}

public enum V2ActorSendMessageResultWire: Codable, Equatable, Sendable {
    case accepted(V2ActorAcceptedMessageWire)
    case idempotent(V2ActorMessageAcceptanceReceiptWire)
    case idempotencyConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
    case denied(V2ActorDirectMessageDeniedWire)
}

public enum V2ActorMessageEditResultWire: Codable, Equatable, Sendable {
    case edited(V2ActorMessageEditWire)
    case idempotent(V2ActorMessageEditWire)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case alreadyWithdrawn
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

public enum V2ActorMessageWithdrawalResultWire: Codable, Equatable, Sendable {
    case withdrawn(V2ActorMessageWithdrawalWire)
    case idempotent(V2ActorMessageWithdrawalWire)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case alreadyWithdrawn
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

public enum V2ActorMessageReactionResultWire: Codable, Equatable, Sendable {
    case changed(V2ActorMessageReactionChangeWire)
    case idempotent(V2ActorMessageReactionChangeWire)
    case idempotencyConflict
    case alreadyInDesiredState
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(V2ActorAdmissionUnavailableWire)
}

/// 结果判别项与命令类型集合对应，同时保留业务字段。
public enum V2RoomMessagingResult: Codable, Equatable, Sendable {
    case failure(V2ActorMessagingErrorWire)
    case send(V2ActorSendMessageResultWire)
    case edit(V2ActorMessageEditResultWire)
    case withdraw(V2ActorMessageWithdrawalResultWire)
    case reaction(V2ActorMessageReactionResultWire)
}
