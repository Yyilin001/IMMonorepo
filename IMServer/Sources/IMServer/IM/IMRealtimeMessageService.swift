import Fluent
import Vapor

struct IMInternalMessageSendRequest: Content, Sendable {
    let payload: IMTCPMessagePayload
    let senderUserID: UUID
}

struct IMRealtimeMessagePersistenceResult: Content, Sendable {
    let conversationID: UUID
    let acknowledgement: IMTCPAckPayload
    let message: IMTCPMessagePayload
    let recipientUserIDs: [UUID]
    let didCreateMessage: Bool
}

struct IMPreparedIncomingMessage: Sendable {
    let payload: IMTCPMessagePayload
    let senderUserID: UUID
    let conversationID: UUID
    let normalizedContent: IMMessageContent
    let normalizedClientMessageID: String?
    let serverTimestamp: Date
}

enum IMRealtimeMessageError: Error, LocalizedError, Equatable, Sendable {
    case invalidConversationID
    case conversationUnavailable
    case unsupportedMessageContent
    case emptyTextBody
    case invalidReplyReference
    case directConversationFrozen
    case strangerDirectMessageLimitReached
    case hotConversationRateLimited
    case messageWriteQueueFull

    var ackStatus: String {
        switch self {
        case .invalidConversationID:
            return "invalid_conversation_id"
        case .conversationUnavailable:
            return "conversation_unavailable"
        case .unsupportedMessageContent:
            return "unsupported_message_content"
        case .emptyTextBody:
            return "empty_text_body"
        case .invalidReplyReference:
            return "invalid_reply_reference"
        case .directConversationFrozen:
            return "direct_conversation_frozen"
        case .strangerDirectMessageLimitReached:
            return "stranger_direct_message_limit_reached"
        case .hotConversationRateLimited:
            return "hot_conversation_rate_limited"
        case .messageWriteQueueFull:
            return "message_write_queue_full"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConversationID:
            return "会话 ID 无效。"
        case .conversationUnavailable:
            return "会话不存在或当前用户不在该会话中。"
        case .unsupportedMessageContent:
            return "当前消息类型不支持发送。"
        case .emptyTextBody:
            return "文本消息不能为空。"
        case .invalidReplyReference:
            return "回复引用无效。"
        case .directConversationFrozen:
            return "你们已不是好友，当前会话不能继续发送消息。"
        case .strangerDirectMessageLimitReached:
            return "你们还不是好友，对方回复前只能发送一条消息。"
        case .hotConversationRateLimited:
            return "当前会话消息过于频繁，请稍后再试。"
        case .messageWriteQueueFull:
            return "当前会话写入队列繁忙，请稍后再试。"
        }
    }
}

struct IMRealtimeMessageService {
    struct ConversationMembershipContext {
        let conversationKind: IMConversationKind
        let directMessagingState: IMDirectMessagingState
        let memberUserIDs: [UUID]
    }

    let app: Application?
    let fixedDatabase: (any Database)?

    init(app: Application) {
        self.app = app
        self.fixedDatabase = nil
    }

    init(fixedDatabaseForLowLevelTest db: any Database) {
        self.app = nil
        self.fixedDatabase = db
    }
}
