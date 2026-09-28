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
    case mutation(V2OperationReference)
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







public struct V2ActorMessageReactionSnapshotWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let messageID: MessageID
    public let reaction: String
    public let requestID: UUID
    public init(roomID: RoomID, actorUserID: UserID, messageID: MessageID, reaction: String, requestID: UUID = UUID()) {
        self.roomID=roomID; self.actorUserID=actorUserID; self.messageID=messageID; self.reaction=reaction; self.requestID=requestID
    }
}

/// D1 房间范围命令族的判别字段。
public enum V2RoomMessagingCommand: Codable, Equatable, Sendable {
    case sendOperation(V2MessageSendOperationCommand)
    case recoverSendOperation(V2MessageSendOperationRecoveryRequest)
    case editOperation(V2MessageEditOperationCommand)
    case withdrawOperation(V2MessageWithdrawalOperationCommand)
    case recoverMutation(V2MessageMutationRecoveryRequest)
    case reactionOperation(V2MessageReactionOperationCommand)
    case recoverReaction(V2MessageReactionRecoveryRequest)
    case reactionSnapshot(V2ActorMessageReactionSnapshotWire)

    public var roomID: RoomID {
        switch self {
        case .reactionOperation(let value): value.roomID
        case .reactionSnapshot(let value): value.roomID
        case .recoverReaction(let value): if case .message(let room,_) = value.identity.scope { room } else { preconditionFailure("validated reaction scope") }
        case .sendOperation(let value): value.command.roomID
        case .recoverSendOperation(let value): if case .room(let room)=value.identity.scope { room } else { preconditionFailure("validated send scope") }
        case .editOperation(let value): value.roomID
        case .withdrawOperation(let value): value.roomID
        case .recoverMutation(let value): if case .message(let room,_) = value.identity.scope { room } else { preconditionFailure("validated mutation scope") }
        }
    }
    public var actorUserID: UserID {
        switch self {
        case .reactionOperation(let value): value.actorUserID
        case .reactionSnapshot(let value): value.actorUserID
        case .recoverReaction(let value): value.identity.accountID
        case .sendOperation(let value): value.command.senderUserID
        case .recoverSendOperation(let value): value.identity.accountID
        case .editOperation(let value): value.actorUserID
        case .withdrawOperation(let value): value.actorUserID
        case .recoverMutation(let value): value.identity.accountID
        }
    }
    public var operationID: V2ActorMessagingOperationID {
        switch self {
        case .reactionOperation(let value): .reaction(value.operationID)
        case .reactionSnapshot(let value): .reaction(.init(uuid:value.requestID))
        case .recoverReaction(let value): .mutation(value.identity.operation)
        case .sendOperation(let value): .send(value.command.clientMessageID)
        case .recoverSendOperation(let value): .mutation(value.identity.operation)
        case .editOperation(let value): .edit(value.operationID)
        case .withdrawOperation(let value): .withdraw(value.operationID)
        case .recoverMutation(let value): .mutation(value.identity.operation)
        }
    }
    /// 四种操作都具有持久化、限定范围的幂等身份。
    public var retryPolicy: V2RoomReplayPolicy { .durableIdempotent }
}
