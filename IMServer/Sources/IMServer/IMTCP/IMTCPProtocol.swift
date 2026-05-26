import Foundation

enum IMTCPPacketType: String, Codable, Sendable {
    case auth
    case authOK = "auth_ok"
    case authError = "auth_error"
    case heartbeat
    case heartbeatAck = "heartbeat_ack"
    case message
    case conversationEvent = "conversation_event"
    case contactEvent = "contact_event"
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

enum IMTCPConversationEventType: String, Codable, Sendable {
    case conversationCreated = "conversation_created"
    case membersAdded = "members_added"
    case memberLeft = "member_left"
    case membersUpdated = "members_updated"
    case conversationRemovedForSelf = "conversation_removed_for_self"
    case summaryUpdated = "summary_updated"
    case messageUpdated = "message_updated"
    case messageRecalled = "message_recalled"
    case messageVisibilityChanged = "message_visibility_changed"
    case messageFavoriteChanged = "message_favorite_changed"
    case conversationVisibilityChanged = "conversation_visibility_changed"
    case conversationSettingsChanged = "conversation_settings_changed"
    case inviteChanged = "invite_changed"
    case messageStreamStarted = "message_stream_started"
    case messageStreamChunk = "message_stream_chunk"
    case messageStreamCompleted = "message_stream_completed"
    case messageStreamFailed = "message_stream_failed"
    case messageStreamCancelled = "message_stream_cancelled"
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

struct IMTCPConversationEventPayload: Codable, Sendable {
    let eventType: IMTCPConversationEventType
    let conversation: IMConversationResponse
    let message: IMMessageResponse?
    let stream: IMTCPMessageStreamPayload?
    let actorUserID: UUID?
    let serverTimestamp: Date
    let messageIDs: [UUID]
    let favoriteChangedMessageID: UUID?
    let isFavorited: Bool?
    let visibilityAction: ConversationVisibilityAction?

    init(
        eventType: IMTCPConversationEventType,
        conversation: IMConversationResponse,
        message: IMMessageResponse?,
        stream: IMTCPMessageStreamPayload? = nil,
        actorUserID: UUID?,
        serverTimestamp: Date,
        messageIDs: [UUID] = [],
        favoriteChangedMessageID: UUID? = nil,
        isFavorited: Bool? = nil,
        visibilityAction: ConversationVisibilityAction? = nil
    ) {
        self.eventType = eventType
        self.conversation = conversation
        self.message = message
        self.stream = stream
        self.actorUserID = actorUserID
        self.serverTimestamp = serverTimestamp
        self.messageIDs = messageIDs
        self.favoriteChangedMessageID = favoriteChangedMessageID
        self.isFavorited = isFavorited
        self.visibilityAction = visibilityAction
    }
}

enum IMTCPContactEventType: String, Codable, Sendable {
    case friendRequestCreated = "friend_request_created"
    case friendRequestAccepted = "friend_request_accepted"
    case friendRequestDeclined = "friend_request_declined"
    case friendRequestCancelled = "friend_request_cancelled"
    case contactRemoved = "contact_removed"
}

struct IMTCPContactEventPayload: Codable, Sendable {
    let eventType: IMTCPContactEventType
    let request: FriendRequestResponse?
    let contact: ContactResponse?
    let contactUserID: UUID?
    let actorUserID: UUID?
    let serverTimestamp: Date
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
