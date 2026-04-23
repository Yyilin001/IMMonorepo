import Foundation

public enum IMTCPPacketType: String, Codable, Sendable {
    case auth
    case authOK = "auth_ok"
    case authError = "auth_error"
    case heartbeat
    case heartbeatAck = "heartbeat_ack"
    case message
    case conversationEvent = "conversation_event"
    case ack
    case kick
}

public enum IMTCPJSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case object([String: IMTCPJSONValue])
    case array([IMTCPJSONValue])
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: IMTCPJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([IMTCPJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON payload")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public func decodePayload<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(self)
        return try decoder.decode(T.self, from: data)
    }
}

public struct IMTCPInboundPacket: Decodable, Sendable {
    public let type: IMTCPPacketType
    public let requestID: UUID?
    public let timestamp: Date?
    public let payload: IMTCPJSONValue
}

public struct IMTCPPacketEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let type: IMTCPPacketType
    public let requestID: UUID?
    public let timestamp: Date
    public let payload: Payload

    public init(
        type: IMTCPPacketType,
        requestID: UUID? = nil,
        timestamp: Date = Date(),
        payload: Payload
    ) {
        self.type = type
        self.requestID = requestID
        self.timestamp = timestamp
        self.payload = payload
    }
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
    public let kind: String
    public let body: [String: String]

    public init(
        clientMessageID: String?,
        messageID: String?,
        conversationID: String,
        senderUserID: UUID?,
        serverSequence: UInt64?,
        serverTimestamp: Date?,
        kind: String,
        body: [String: String]
    ) {
        self.clientMessageID = clientMessageID
        self.messageID = messageID
        self.conversationID = conversationID
        self.senderUserID = senderUserID
        self.serverSequence = serverSequence
        self.serverTimestamp = serverTimestamp
        self.kind = kind
        self.body = body
    }
}

public enum IMTCPConversationEventType: String, Codable, Equatable, Sendable {
    case conversationCreated = "conversation_created"
    case membersAdded = "members_added"
    case memberLeft = "member_left"
    case conversationRemovedForSelf = "conversation_removed_for_self"
    case summaryUpdated = "summary_updated"
}

public struct IMTCPConversationEventPayload: Codable, Equatable, Sendable {
    public let eventType: IMTCPConversationEventType
    public let conversation: IMConversationSummaryResponseBody
    public let actorUserID: UUID?
    public let serverTimestamp: Date

    public init(
        eventType: IMTCPConversationEventType,
        conversation: IMConversationSummaryResponseBody,
        actorUserID: UUID?,
        serverTimestamp: Date
    ) {
        self.eventType = eventType
        self.conversation = conversation
        self.actorUserID = actorUserID
        self.serverTimestamp = serverTimestamp
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
        host: String = AppConstants.imTCPHost,
        port: UInt16 = AppConstants.imTCPPort,
        protocolVersion: Int = 1,
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
    case message(requestID: UUID?, payload: IMTCPMessagePayload)
    case conversationEvent(requestID: UUID?, payload: IMTCPConversationEventPayload)
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

    private let sendLine: @Sendable (String) async throws -> Void
    private let disconnectHandler: @Sendable () async -> Void

    init(
        authentication: IMTCPAuthAcceptedPayload,
        events: AsyncThrowingStream<IMTCPConnectionEvent, Error>,
        sendLine: @escaping @Sendable (String) async throws -> Void,
        disconnectHandler: @escaping @Sendable () async -> Void
    ) {
        self.authentication = authentication
        self.events = events
        self.sendLine = sendLine
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
        try await sendPacket(type: .message, requestID: requestID, payload: payload)
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
        let line = try IMTCPPacketCodec.encode(
            IMTCPPacketEnvelope(type: type, requestID: requestID, payload: payload)
        )
        try await sendLine(line)
    }
}

public struct IMTCPClient: Sendable {
    public let configuration: IMTCPClientConfiguration

    private let connectTransport: @Sendable (String, UInt16) async throws -> IMTCPTransportConnection
    private let accessTokenProvider: @Sendable () async throws -> String

    init(
        configuration: IMTCPClientConfiguration = IMTCPClientConfiguration(),
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
        configuration: IMTCPClientConfiguration = IMTCPClientConfiguration(),
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
                for try await line in transportConnection.lines {
                    await eventRouter.consume(line: line)
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
            try await send(
                IMTCPPacketEnvelope(type: .auth, payload: authPayload),
                via: transportConnection
            )

            let authentication = try await eventRouter.waitForAuthentication()

            return IMTCPConnection(
                authentication: authentication,
                events: events,
                sendLine: { line in
                    try await transportConnection.sendLine(line)
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

    private func send<Payload: Codable & Sendable>(
        _ envelope: IMTCPPacketEnvelope<Payload>,
        via connection: IMTCPTransportConnection
    ) async throws {
        let line = try IMTCPPacketCodec.encode(envelope)
        try await connection.sendLine(line)
    }
}

private enum IMTCPPacketCodec {
    public static func encode<Payload: Codable & Sendable>(_ envelope: IMTCPPacketEnvelope<Payload>) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        guard let line = String(data: data, encoding: .utf8) else {
            throw IMTCPClientError.invalidPacket
        }

        return line
    }

    public static func decode(_ line: String) throws -> IMTCPInboundPacket {
        guard let data = line.data(using: .utf8) else {
            throw IMTCPClientError.invalidPacket
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IMTCPInboundPacket.self, from: data)
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

    public func consume(line: String) {
        guard !finished else {
            return
        }

        do {
            let packet = try IMTCPPacketCodec.decode(line)
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

        case .message:
            do {
                let payload = try packet.payload.decodePayload(IMTCPMessagePayload.self)
                continuation.yield(.message(requestID: packet.requestID, payload: payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.message))
            }

        case .conversationEvent:
            do {
                let payload = try packet.payload.decodePayload(IMTCPConversationEventPayload.self)
                continuation.yield(.conversationEvent(requestID: packet.requestID, payload: payload))
            } catch {
                finish(with: IMTCPClientError.invalidPayload(.conversationEvent))
            }

        case .kick:
            let payload = (try? packet.payload.decodePayload(IMTCPKickPayload.self))
                ?? IMTCPKickPayload(reason: .protocolError, message: "连接已被服务端关闭。")
            continuation.yield(.kick(payload))
            finished = true
            continuation.finish()

        case .auth, .authOK, .authError, .heartbeat:
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
