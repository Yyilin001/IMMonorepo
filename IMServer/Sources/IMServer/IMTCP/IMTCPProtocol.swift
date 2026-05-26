import Foundation

enum IMTCPPacketType: String, Codable, Sendable {
    case auth
    case authOK = "auth_ok"
    case authError = "auth_error"
    case heartbeat
    case heartbeatAck = "heartbeat_ack"
    case sendMessage = "send_message"
    case domainEvent = "domain_event"
    case ack
    case kick
}

enum IMTCPProtocolError: Error, LocalizedError, Sendable {
    case frameTooLarge
    case invalidEnvelope
    case authRequired
    case duplicateAuth
    case unsupportedPacketType
    case unsupportedProtocolVersion(Int)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge:
            return "TCP frame exceeds the configured size limit."
        case .invalidEnvelope:
            return "Invalid TCP packet envelope."
        case .authRequired:
            return "Authentication must be the first packet."
        case .duplicateAuth:
            return "Connection is already authenticated."
        case .unsupportedPacketType:
            return "Unsupported packet type."
        case .unsupportedProtocolVersion(let version):
            return "Unsupported protocol version: \(version)."
        }
    }
}

struct IMTCPAuthRequestPayload: Codable, Sendable {
    let accessToken: String
    let deviceID: String?
    let deviceName: String?
    let platform: String?
    let appVersion: String?
    let protocolVersion: Int
}

struct IMTCPAuthAcceptedPayload: Codable, Sendable {
    let connectionID: UUID
    let userID: UUID
    let sessionID: UUID
    let heartbeatIntervalSeconds: Int
    let serverTime: Date
}

struct IMTCPAuthErrorPayload: Codable, Sendable {
    let code: String
    let message: String
}

struct IMTCPHeartbeatPayload: Codable, Sendable {
    let sequence: Int
}

struct IMTCPAckPayload: Codable, Sendable {
    let messageID: String
    let conversationID: String?
    let status: String
}

struct IMTCPMessagePayload: Codable, Sendable {
    let clientMessageID: String?
    let messageID: String?
    let conversationID: String
    let senderUserID: UUID?
    let serverSequence: UInt64?
    let serverTimestamp: Date?
    let content: IMMessageContent
    let derivedState: IMMessageDerivedState

    init(
        clientMessageID: String?,
        messageID: String?,
        conversationID: String,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        serverTimestamp: Date?,
        content: IMMessageContent,
        derivedState: IMMessageDerivedState = IMMessageDerivedState()
    ) {
        self.clientMessageID = clientMessageID
        self.messageID = messageID
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.serverTimestamp = serverTimestamp
        self.content = content
        self.derivedState = derivedState
    }
}

struct IMTCPMessageStreamPayload: Codable, Equatable, Sendable {
    let streamID: String
    let messageID: String
    let conversationID: String
    let chunkIndex: Int
    let deltaText: String?
    let partialTextLength: Int
    let state: MessageStreamLifecycleState
    let serverTimestamp: Date
}

enum IMTCPChatDomainEventType: String, Codable, Sendable {
    case messageCreated = "message_created"
    case messageEdited = "message_edited"
    case messageRevoked = "message_revoked"
    case messageVisibilityChanged = "message_visibility_changed"
    case messageFavoriteChanged = "message_favorite_changed"
    case messageStreamStarted = "message_stream_started"
    case messageStreamChunk = "message_stream_chunk"
    case messageStreamCompleted = "message_stream_completed"
    case messageStreamFailed = "message_stream_failed"
    case messageStreamCancelled = "message_stream_cancelled"
    case conversationCreated = "conversation_created"
    case conversationUpdated = "conversation_updated"
    case conversationRemovedForSelf = "conversation_removed_for_self"
    case conversationSettingsChanged = "conversation_settings_changed"
    case conversationVisibilityChanged = "conversation_visibility_changed"
    case memberAdded = "member_added"
    case memberRemoved = "member_removed"
    case memberRoleUpdated = "member_role_updated"
    case contactRequestCreated = "contact_request_created"
    case contactRequestAccepted = "contact_request_accepted"
    case contactRequestUpdated = "contact_request_updated"
}

enum IMTCPChatDomainEventBody: Sendable {
    case messageCreated(message: IMMessageResponse, clientMessageID: String?)
    case messageEdited(messageID: UUID, body: IMRichTextContent, editedAt: Date, message: IMMessageResponse?)
    case messageRevoked(messageID: UUID, revokedAt: Date, revokedByUserID: UUID?, message: IMMessageResponse?)
    case messageVisibilityChanged(messageIDs: [UUID], message: IMMessageResponse?, visibilityAction: ConversationVisibilityAction?)
    case messageFavoriteChanged(messageID: UUID, isFavorited: Bool)
    case messageStream(IMTCPMessageStreamPayload, message: IMMessageResponse?)
    case conversationChanged
    case conversationRemovedForSelf
    case conversationVisibilityChanged(visibilityAction: ConversationVisibilityAction, messageIDs: [UUID])
    case memberChanged(memberUserIDs: [UUID])
    case contactChanged(request: FriendRequestResponse?, contact: ContactResponse?, contactUserID: UUID?)
}

struct IMTCPChatDomainEventPayload: Sendable {
    let eventID: UUID
    let eventType: IMTCPChatDomainEventType
    let aggregateType: String
    let aggregateID: UUID
    let aggregateSequence: UInt64
    let occurredAt: Date
    let actorUserID: UUID?
    let conversation: IMConversationResponse?
    let body: IMTCPChatDomainEventBody
}

enum IMTCPKickReason: String, Codable, Sendable {
    case sessionRevoked = "session_revoked"
    case logoutCurrent = "logout_current"
    case logoutAll = "logout_all"
    case duplicateConnection = "duplicate_connection"
    case serverShutdown = "server_shutdown"
    case protocolError = "protocol_error"
}

struct IMTCPKickPayload: Codable, Sendable {
    let reason: IMTCPKickReason
    let message: String
}
