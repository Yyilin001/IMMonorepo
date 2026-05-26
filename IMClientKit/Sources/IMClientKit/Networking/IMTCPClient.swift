import Foundation

public enum IMTCPPacketType: String, Codable, Sendable {
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

public struct IMTCPAuthRequestPayload: Codable, Equatable, Sendable {
    public let accessToken: String
    public let deviceID: String?
    public let deviceName: String?
    public let platform: String?
    public let appVersion: String?
    public let protocolVersion: Int
}

public struct IMTCPAuthAcceptedPayload: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let userID: UUID
    public let sessionID: UUID
    public let heartbeatIntervalSeconds: Int
    public let serverTime: Date

    public init(
        connectionID: UUID,
        userID: UUID,
        sessionID: UUID,
        heartbeatIntervalSeconds: Int,
        serverTime: Date
    ) {
        self.connectionID = connectionID
        self.userID = userID
        self.sessionID = sessionID
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.serverTime = serverTime
    }
}

public struct IMTCPAuthErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct IMTCPHeartbeatPayload: Codable, Equatable, Sendable {
    public let sequence: Int
}

public struct IMTCPAckPayload: Codable, Equatable, Sendable {
    public let messageID: String
    public let conversationID: String?
    public let status: String

    public init(messageID: String, conversationID: String?, status: String) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.status = status
    }
}

public struct IMTCPMessagePayload: Codable, Equatable, Sendable {
    public let clientMessageID: String?
    public let messageID: String?
    public let conversationID: String
    public let senderUserID: UUID?
    public let serverSequence: UInt64?
    public let serverTimestamp: Date?
    public let content: IMMessageContent
    public let derivedState: IMMessageDerivedState

    public var textValue: String? {
        content.textValue
    }

    public init(
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

public enum IMTCPConversationVisibilityAction: String, Codable, Equatable, Sendable {
    case messageHidden = "message_hidden"
    case conversationCleared = "conversation_cleared"
    case conversationDeleted = "conversation_deleted"
}

public struct IMTCPMessageStreamPayload: Codable, Equatable, Sendable {
    public let streamID: String
    public let messageID: String
    public let conversationID: String
    public let chunkIndex: Int
    public let deltaText: String?
    public let partialTextLength: Int
    public let state: MessageStreamLifecycleState
    public let serverTimestamp: Date

    public init(
        streamID: String,
        messageID: String,
        conversationID: String,
        chunkIndex: Int,
        deltaText: String? = nil,
        partialTextLength: Int,
        state: MessageStreamLifecycleState,
        serverTimestamp: Date
    ) {
        self.streamID = streamID
        self.messageID = messageID
        self.conversationID = conversationID
        self.chunkIndex = chunkIndex
        self.deltaText = deltaText
        self.partialTextLength = partialTextLength
        self.state = state
        self.serverTimestamp = serverTimestamp
    }
}

public enum IMTCPChatDomainEventType: String, Codable, Equatable, Sendable {
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

public enum IMTCPChatDomainEventBody: Equatable, Sendable {
    case messageCreated(message: IMConversationMessageResponseBody, clientMessageID: String?)
    case messageEdited(messageID: UUID, body: IMRichTextContent, editedAt: Date, message: IMConversationMessageResponseBody?)
    case messageRevoked(messageID: UUID, revokedAt: Date, revokedByUserID: UUID?, message: IMConversationMessageResponseBody?)
    case messageVisibilityChanged(messageIDs: [UUID], message: IMConversationMessageResponseBody?, visibilityAction: IMTCPConversationVisibilityAction?)
    case messageFavoriteChanged(messageID: UUID, isFavorited: Bool)
    case messageStream(IMTCPMessageStreamPayload, message: IMConversationMessageResponseBody?)
    case conversationChanged
    case conversationRemovedForSelf
    case conversationVisibilityChanged(visibilityAction: IMTCPConversationVisibilityAction, messageIDs: [UUID])
    case memberChanged(memberUserIDs: [UUID])
    case contactChanged(request: ContactRequestResponseBody?, contact: ContactResponseBody?, contactUserID: UUID?)
}

public struct IMTCPChatDomainEventPayload: Equatable, Sendable {
    public let eventID: UUID
    public let eventType: IMTCPChatDomainEventType
    public let aggregateType: String
    public let aggregateID: UUID
    public let aggregateSequence: UInt64
    public let occurredAt: Date
    public let actorUserID: UUID?
    public let conversation: IMConversationSummaryResponseBody?
    public let body: IMTCPChatDomainEventBody

    public init(
        eventID: UUID,
        eventType: IMTCPChatDomainEventType,
        aggregateType: String,
        aggregateID: UUID,
        aggregateSequence: UInt64,
        occurredAt: Date,
        actorUserID: UUID?,
        conversation: IMConversationSummaryResponseBody?,
        body: IMTCPChatDomainEventBody
    ) {
        self.eventID = eventID
        self.eventType = eventType
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.aggregateSequence = aggregateSequence
        self.occurredAt = occurredAt
        self.actorUserID = actorUserID
        self.conversation = conversation
        self.body = body
    }
}

public enum IMTCPKickReason: String, Codable, Equatable, Sendable {
    case sessionRevoked = "session_revoked"
    case logoutCurrent = "logout_current"
    case logoutAll = "logout_all"
    case duplicateConnection = "duplicate_connection"
    case serverShutdown = "server_shutdown"
    case protocolError = "protocol_error"
}

public struct IMTCPKickPayload: Codable, Equatable, Sendable {
    public let reason: IMTCPKickReason
    public let message: String

    public init(reason: IMTCPKickReason, message: String) {
        self.reason = reason
        self.message = message
    }
}

public struct IMTCPClientConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let protocolVersion: Int
    public let deviceID: String?
    public let deviceName: String?
    public let platform: String?
    public let appVersion: String?

    public init(
        host: String,
        port: UInt16,
        protocolVersion: Int = 4,
        deviceID: String? = nil,
        deviceName: String? = nil,
        platform: String? = "ios",
        appVersion: String? = nil
    ) {
        self.host = host
        self.port = port
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public enum IMTCPConnectionEvent: Equatable, Sendable {
    case heartbeatAck(requestID: UUID?, payload: IMTCPHeartbeatPayload)
    case ack(requestID: UUID?, payload: IMTCPAckPayload)
    case domainEvent(requestID: UUID?, payload: IMTCPChatDomainEventPayload)
    case kick(IMTCPKickPayload)
}

public enum IMTCPClientError: LocalizedError, Equatable, Sendable {
    case invalidPacket
    case invalidPayload(IMTCPPacketType)
    case unexpectedPacket(IMTCPPacketType)
    case authRejected(code: String, message: String)
    case kicked(reason: IMTCPKickReason, message: String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .invalidPacket:
            return "TCP 数据包格式无效。"
        case .invalidPayload(let packetType):
            return "收到的 \(packetType.rawValue) payload 无法解析。"
        case .unexpectedPacket(let packetType):
            return "收到未预期的 \(packetType.rawValue) 数据包。"
        case .authRejected(_, let message):
            return message
        case .kicked(_, let message):
            return message
        case .connectionClosed:
            return "TCP 连接已关闭。"
        }
    }
}

public struct IMTCPConnection: Sendable {
    public let authentication: IMTCPAuthAcceptedPayload
    public let events: AsyncThrowingStream<IMTCPConnectionEvent, Error>

    private let sendFrame: @Sendable (Data) async throws -> Void
    private let disconnectHandler: @Sendable () async -> Void

    init(
        authentication: IMTCPAuthAcceptedPayload,
        events: AsyncThrowingStream<IMTCPConnectionEvent, Error>,
        sendFrame: @escaping @Sendable (Data) async throws -> Void,
        disconnectHandler: @escaping @Sendable () async -> Void
    ) {
        self.authentication = authentication
        self.events = events
        self.sendFrame = sendFrame
        self.disconnectHandler = disconnectHandler
    }

    public func sendHeartbeat(sequence: Int, requestID: UUID = UUID()) async throws {
        try await sendPacket(
            type: .heartbeat,
            requestID: requestID,
            payload: IMTCPHeartbeatPayload(sequence: sequence)
        )
    }

    public func sendMessage(_ payload: IMTCPMessagePayload, requestID: UUID = UUID()) async throws {
        try await sendPacket(type: .sendMessage, requestID: requestID, payload: payload)
    }

    public func sendAcknowledgement(_ payload: IMTCPAckPayload, requestID: UUID? = UUID()) async throws {
        try await sendPacket(type: .ack, requestID: requestID, payload: payload)
    }

    public func disconnect() async {
        await disconnectHandler()
    }

    private func sendPacket<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload
    ) async throws {
        let frame = try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
        try await sendFrame(frame)
    }
}

public struct IMTCPClient: Sendable {
    public let configuration: IMTCPClientConfiguration

    private let connectTransport: @Sendable (String, UInt16) async throws -> IMTCPTransportConnection
    private let accessTokenProvider: @Sendable () async throws -> String

    init(
        configuration: IMTCPClientConfiguration,
        transport: NWIMTCPTransport = NWIMTCPTransport(),
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.init(
            configuration: configuration,
            connectTransport: { host, port in
                try await transport.connect(host: host, port: port)
            },
            accessTokenProvider: accessTokenProvider
        )
    }

    init<Transport: IMTCPTransport>(
        configuration: IMTCPClientConfiguration,
        transport: Transport,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.init(
            configuration: configuration,
            connectTransport: { host, port in
                try await transport.connect(host: host, port: port)
            },
            accessTokenProvider: accessTokenProvider
        )
    }

    private init(
        configuration: IMTCPClientConfiguration,
        connectTransport: @escaping @Sendable (String, UInt16) async throws -> IMTCPTransportConnection,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.configuration = configuration
        self.connectTransport = connectTransport
        self.accessTokenProvider = accessTokenProvider
    }

    public func connect() async throws -> IMTCPConnection {
        let accessToken = try await accessTokenProvider()
        let transportConnection = try await connectTransport(configuration.host, configuration.port)
        let eventRouter = IMTCPEventRouter()
        let events = await eventRouter.makeEvents()

        let readerTask = Task {
            do {
                for try await frame in transportConnection.frames {
                    await eventRouter.consume(frame: frame)
                }
                await eventRouter.finish(with: nil)
            } catch {
                await eventRouter.finish(with: error)
            }
        }

        do {
            let authPayload = IMTCPAuthRequestPayload(
                accessToken: accessToken,
                deviceID: configuration.deviceID,
                deviceName: configuration.deviceName,
                platform: configuration.platform,
                appVersion: configuration.appVersion,
                protocolVersion: configuration.protocolVersion
            )
            try await send(type: .auth, requestID: nil, payload: authPayload, via: transportConnection)

            let authentication = try await eventRouter.waitForAuthentication()

            return IMTCPConnection(
                authentication: authentication,
                events: events,
                sendFrame: { frame in
                    try await transportConnection.sendFrame(frame)
                },
                disconnectHandler: {
                    readerTask.cancel()
                    await transportConnection.disconnect()
                }
            )
        } catch {
            readerTask.cancel()
            await transportConnection.disconnect()
            throw error
        }
    }

    private func send<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        via connection: IMTCPTransportConnection
    ) async throws {
        let frame = try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
        try await connection.sendFrame(frame)
    }
}

private actor IMTCPEventRouter {
    private let events: AsyncThrowingStream<IMTCPConnectionEvent, Error>
    private let continuation: AsyncThrowingStream<IMTCPConnectionEvent, Error>.Continuation

    private var authenticationResult: Result<IMTCPAuthAcceptedPayload, Error>?
    private var authenticationWaiters: [CheckedContinuation<IMTCPAuthAcceptedPayload, Error>] = []
    private var finished = false

    init() {
        var capturedContinuation: AsyncThrowingStream<IMTCPConnectionEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    public func makeEvents() -> AsyncThrowingStream<IMTCPConnectionEvent, Error> {
        events
    }

    public func waitForAuthentication() async throws -> IMTCPAuthAcceptedPayload {
        if let authenticationResult {
            return try authenticationResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            authenticationWaiters.append(continuation)
        }
    }

    public func consume(frame: Data) {
        guard !finished else {
            return
        }

        do {
            let packet = try IMTCPProtobufCodec.decode(frame)
            if authenticationResult == nil {
                handleAuthentication(packet: packet)
            } else {
                handleEvent(packet: packet)
            }
        } catch {
            finish(with: error)
        }
    }

    public func finish(with error: Error?) {
        guard !finished else {
            return
        }

        if let error {
            resolveAuthentication(with: .failure(error))
            continuation.finish(throwing: error)
        } else {
            resolveAuthentication(with: .failure(IMTCPClientError.connectionClosed))
            continuation.finish()
        }

        finished = true
    }

    private func handleAuthentication(packet: IMTCPInboundPacket) {
        switch packet.type {
        case .authOK:
            do {
                let payload = try packet.payload.decodePayload(IMTCPAuthAcceptedPayload.self)
                resolveAuthentication(with: .success(payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.authOK))
            }

        case .authError:
            let payload = (try? packet.payload.decodePayload(IMTCPAuthErrorPayload.self))
                ?? IMTCPAuthErrorPayload(code: "auth_error", message: "TCP 登录失败。")
            finish(with: IMTCPClientError.authRejected(code: payload.code, message: payload.message))

        case .kick:
            let payload = (try? packet.payload.decodePayload(IMTCPKickPayload.self))
                ?? IMTCPKickPayload(reason: .protocolError, message: "连接已被服务端关闭。")
            finish(with: IMTCPClientError.kicked(reason: payload.reason, message: payload.message))

        default:
            finish(with: IMTCPClientError.unexpectedPacket(packet.type))
        }
    }

    private func handleEvent(packet: IMTCPInboundPacket) {
        switch packet.type {
        case .heartbeatAck:
            do {
                let payload = try packet.payload.decodePayload(IMTCPHeartbeatPayload.self)
                continuation.yield(.heartbeatAck(requestID: packet.requestID, payload: payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.heartbeatAck))
            }

        case .ack:
            do {
                let payload = try packet.payload.decodePayload(IMTCPAckPayload.self)
                continuation.yield(.ack(requestID: packet.requestID, payload: payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.ack))
            }

        case .domainEvent:
            do {
                let payload = try packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
                continuation.yield(.domainEvent(requestID: packet.requestID, payload: payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.domainEvent))
            }

        case .kick:
            let payload = (try? packet.payload.decodePayload(IMTCPKickPayload.self))
                ?? IMTCPKickPayload(reason: .protocolError, message: "连接已被服务端关闭。")
            continuation.yield(.kick(payload))
            finished = true
            continuation.finish()

        case .auth, .authOK, .authError, .heartbeat, .sendMessage:
            finish(with: IMTCPClientError.unexpectedPacket(packet.type))
        }
    }

    private func resolveAuthentication(with result: Result<IMTCPAuthAcceptedPayload, Error>) {
        guard authenticationResult == nil else {
            return
        }

        authenticationResult = result
        let waiters = authenticationWaiters
        authenticationWaiters.removeAll()

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
