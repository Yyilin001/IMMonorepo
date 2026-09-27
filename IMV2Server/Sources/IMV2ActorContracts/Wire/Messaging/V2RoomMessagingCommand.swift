import Foundation
import IMV2Core

/// 房间消息操作携带身份，不携带服务器生成的事件 ID 或时钟。
public enum V2ActorMentionTargetWire: Codable, Equatable, Sendable {
    case user(UserID)
    case everyone
}

public enum V2ActorMessagingOperationID: Codable, Equatable, Sendable {
    case send(ClientMessageID)
    case edit(MessageEditOperationID)
    case withdraw(MessageWithdrawalOperationID)
    case reaction(MessageReactionOperationID)
    case recover(ClientMessageID)
}

public struct V2ActorMessageRecoveryWire: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let request: V2MessageOperationRecoveryRequest
    public init(actorUserID: UserID, request: V2MessageOperationRecoveryRequest) {
        self.actorUserID = actorUserID; self.request = request
    }
}

public struct V2ActorSendMessageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2ActorMentionTargetWire]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?

    public init(roomID: RoomID, actorUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2ActorMentionTargetWire], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

public struct V2ActorEditMessageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageEditOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64
    public let text: String

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
        self.text = text
    }
}

public struct V2ActorWithdrawMessageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageWithdrawalOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
    }
}

public struct V2ActorReactionMessageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageReactionOperationID
    public let messageID: MessageID
    public let reaction: String
    public let action: V2MessageReactionAction

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.reaction = reaction
        self.action = action
    }
}

/// D1 房间范围命令族的判别字段。
public enum V2RoomMessagingCommand: Codable, Equatable, Sendable {
    case send(V2ActorSendMessageWire)
    case edit(V2ActorEditMessageWire)
    case withdraw(V2ActorWithdrawMessageWire)
    case reaction(V2ActorReactionMessageWire)
    case recover(V2ActorMessageRecoveryWire)

    public var roomID: RoomID {
        switch self {
        case .send(let value): value.roomID
        case .edit(let value): value.roomID
        case .withdraw(let value): value.roomID
        case .reaction(let value): value.roomID
        case .recover(let value): value.request.roomID
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .send(let value): value.actorUserID
        case .edit(let value): value.actorUserID
        case .withdraw(let value): value.actorUserID
        case .reaction(let value): value.actorUserID
        case .recover(let value): value.actorUserID
        }
    }
    public var operationID: V2ActorMessagingOperationID {
        switch self {
        case .send(let value): .send(value.clientMessageID)
        case .edit(let value): .edit(value.operationID)
        case .withdraw(let value): .withdraw(value.operationID)
        case .reaction(let value): .reaction(value.operationID)
        case .recover(let value): .recover(value.request.clientMessageID)
        }
    }
    /// 四种操作都具有持久化、限定范围的幂等身份。
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}
