import Foundation
import Testing
@testable import IMClientKit

struct IMTCPClientTests {
    private static let connectionID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private static let userID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    private static let sessionID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    @Test func connectSendsAuthPacketAndReturnsAuthenticationContext() async throws {
        let wire = MockIMTCPWire()
        let transport = MockIMTCPTransport { host, port in
            #expect(host == "127.0.0.1")
            #expect(port == 9000)
            return await wire.makeConnection()
        }
        let configuration = IMTCPClientConfiguration(
            host: "127.0.0.1",
            port: 9000,
            protocolVersion: IMRealtimeProtocolVersion.currentInt,
            deviceID: "device-1",
            deviceName: "iPhone",
            platform: "ios",
            appVersion: "1.0.0"
        )

        let client = IMTCPClient(configuration: configuration, transport: transport) {
            "access-123"
        }

        let connectTask = Task {
            try await client.connect()
        }

        let authFrame = try await requireRecordedFrame(at: 0, from: wire)
        let (authPacket, authPayload) = try decodePayload(IMTCPAuthRequestPayload.self, from: authFrame)
        #expect(authPacket.type == .auth)
        #expect(authPayload.accessToken == "access-123")
        #expect(authPayload.deviceID == "device-1")
        #expect(authPayload.deviceName == "iPhone")
        #expect(authPayload.platform == "ios")
        #expect(authPayload.appVersion == "1.0.0")
        #expect(authPacket.protocolVersion == IMRealtimeProtocolVersion.current)

        await wire.yieldIncoming(
            try encodeFrame(
                type: .authOK,
                payload: IMTCPAuthAcceptedPayload(
                    connectionID: Self.connectionID,
                    userID: Self.userID,
                    sessionID: Self.sessionID,
                    heartbeatIntervalSeconds: 30,
                    serverTime: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        )

        let connection = try await connectTask.value
        #expect(connection.authentication.connectionID == Self.connectionID)
        #expect(connection.authentication.userID == Self.userID)
        #expect(connection.authentication.sessionID == Self.sessionID)
        #expect(connection.authentication.heartbeatIntervalSeconds == 30)
    }

    @Test func heartbeatDomainEventAndKickAreDeliveredAsEvents() async throws {
        let wire = MockIMTCPWire()
        let transport = MockIMTCPTransport { _, _ in
            await wire.makeConnection()
        }
        let client = IMTCPClient(
            configuration: IMTCPClientConfiguration(host: "127.0.0.1", port: 9000),
            transport: transport
        ) {
            "access-456"
        }

        let connectTask = Task {
            try await client.connect()
        }

        _ = try await requireRecordedFrame(at: 0, from: wire)

        await wire.yieldIncoming(
            try encodeFrame(
                type: .authOK,
                payload: IMTCPAuthAcceptedPayload(
                    connectionID: Self.connectionID,
                    userID: Self.userID,
                    sessionID: Self.sessionID,
                    heartbeatIntervalSeconds: 20,
                    serverTime: Date(timeIntervalSince1970: 1_700_000_100)
                )
            )
        )

        let connection = try await connectTask.value
        var iterator = connection.events.makeAsyncIterator()
        let heartbeatRequestID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!

        try await connection.sendHeartbeat(sequence: 7, requestID: heartbeatRequestID)
        let heartbeatFrame = try await requireRecordedFrame(at: 1, from: wire)
        let (heartbeatPacket, heartbeatPayload) = try decodePayload(IMTCPHeartbeatPayload.self, from: heartbeatFrame)
        #expect(heartbeatPacket.type == .heartbeat)
        #expect(heartbeatPacket.requestID == heartbeatRequestID)
        #expect(heartbeatPayload.sequence == 7)

        await wire.yieldIncoming(
            try encodeFrame(
                type: .heartbeatAck,
                requestID: heartbeatRequestID,
                payload: IMTCPHeartbeatPayload(sequence: 7)
            )
        )

        let heartbeatEvent = try await iterator.next()
        #expect(heartbeatEvent == .heartbeatAck(requestID: heartbeatRequestID, payload: IMTCPHeartbeatPayload(sequence: 7)))

        let domainEventRequestID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let conversationID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let messageID = UUID(uuidString: "13131313-3434-5656-7878-909090909090")!
        let message = IMConversationMessageResponseBody(
            id: messageID,
            conversationID: conversationID,
            senderUserID: Self.userID,
            clientMessageID: "client-msg-1",
            serverSequence: 7,
            timelineSequence: 7,
            content: .richText(.plain("hello")),
            createdAt: Date(timeIntervalSince1970: 1_700_000_101)
        )
        let domainEventPayload = IMTCPChatDomainEventPayload(
            eventID: messageID,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 7,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_101),
            actorUserID: Self.userID,
            conversation: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "Realtime Conversation",
                memberUserIDs: [Self.userID],
                lastMessage: IMMessagePreviewResponseBody(
                    id: messageID,
                    senderUserID: Self.userID,
                    serverSequence: 7,
                    timelineSequence: 7,
                    content: .richText(.plain("hello")),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_101)
                ),
                lastReadSequence: 7,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_101)
            ),
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .messageCreated(message: message, clientMessageID: "client-msg-1")
        )

        await wire.yieldIncoming(
            try encodeFrame(
                type: .domainEvent,
                requestID: domainEventRequestID,
                payload: domainEventPayload
            )
        )

        let domainEvent = try await iterator.next()
        #expect(domainEvent == .domainEvent(requestID: domainEventRequestID, payload: domainEventPayload))

        await wire.yieldIncoming(
            try encodeFrame(
                type: .kick,
                payload: IMTCPKickPayload(reason: .logoutAll, message: "已在其他设备退出登录。")
            )
        )

        let kickEvent = try await iterator.next()
        #expect(kickEvent == .kick(IMTCPKickPayload(reason: .logoutAll, message: "已在其他设备退出登录。")))
        let terminalEvent = try await iterator.next()
        #expect(terminalEvent == nil)
    }

    @Test func deliveryAcknowledgementUsesAckPacket() async throws {
        let wire = MockIMTCPWire()
        let transport = MockIMTCPTransport { _, _ in
            await wire.makeConnection()
        }
        let client = IMTCPClient(
            configuration: IMTCPClientConfiguration(host: "127.0.0.1", port: 9000),
            transport: transport
        ) {
            "access-789"
        }

        let connectTask = Task {
            try await client.connect()
        }

        _ = try await requireRecordedFrame(at: 0, from: wire)

        await wire.yieldIncoming(
            try encodeFrame(
                type: .authOK,
                payload: IMTCPAuthAcceptedPayload(
                    connectionID: Self.connectionID,
                    userID: Self.userID,
                    sessionID: Self.sessionID,
                    heartbeatIntervalSeconds: 20,
                    serverTime: Date(timeIntervalSince1970: 1_700_000_300)
                )
            )
        )

        let connection = try await connectTask.value
        let requestID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!

        try await connection.sendAcknowledgement(
            IMTCPAckPayload(
                messageID: "srv-msg-2",
                conversationID: "conv-100",
                status: "received"
            ),
            requestID: requestID
        )

        let ackFrame = try await requireRecordedFrame(at: 1, from: wire)
        let (ackPacket, ackPayload) = try decodePayload(IMTCPAckPayload.self, from: ackFrame)
        #expect(ackPacket.type == .ack)
        #expect(ackPacket.requestID == requestID)
        #expect(ackPayload.messageID == "srv-msg-2")
        #expect(ackPayload.conversationID == "conv-100")
        #expect(ackPayload.status == "received")
    }

    @Test func sessionClientRefreshesAccessTokenBeforeTCPHandshake() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        try tokenStore.save("refresh-1", for: "refresh_token")

        let httpTransport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"):
                let body = try Self.authResponseBody(accessToken: "tcp-access", refreshToken: "refresh-2")
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let wire = MockIMTCPWire()
        let tcpTransport = MockIMTCPTransport { _, _ in
            await wire.makeConnection()
        }
        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: httpTransport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let connectTask = Task {
            try await client.openIMConnection(
                configuration: IMTCPClientConfiguration(host: "127.0.0.1", port: 9000),
                transport: tcpTransport
            )
        }

        let authFrame = try await requireRecordedFrame(at: 0, from: wire)
        let (_, authPayload) = try decodePayload(IMTCPAuthRequestPayload.self, from: authFrame)
        #expect(authPayload.accessToken == "tcp-access")

        await wire.yieldIncoming(
            try encodeFrame(
                type: .authOK,
                payload: IMTCPAuthAcceptedPayload(
                    connectionID: Self.connectionID,
                    userID: Self.userID,
                    sessionID: Self.sessionID,
                    heartbeatIntervalSeconds: 30,
                    serverTime: Date(timeIntervalSince1970: 1_700_000_200)
                )
            )
        )

        _ = try await connectTask.value

        let requests = await httpTransport.requests()
        #expect(requests.map(\.url?.path) == ["/api/auth/refresh"])
        #expect(try tokenStore.readString(for: "refresh_token") == "refresh-2")
    }

    private func requireRecordedFrame(at index: Int, from wire: MockIMTCPWire) async throws -> Data {
        for _ in 0..<50 {
            let frames = await wire.recordedFrames()
            if frames.indices.contains(index) {
                return frames[index]
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待第 \(index) 条 TCP 发送数据超时。")
        throw IMTCPClientError.connectionClosed
    }

    private func encodeFrame<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID? = nil,
        payload: Payload
    ) throws -> Data {
        try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
    }

    private func decodePayload<T: Sendable>(
        _: T.Type,
        from frame: Data
    ) throws -> (packet: IMTCPInboundPacket, payload: T) {
        let packet = try IMTCPProtobufCodec.decode(frame)
        return (packet, try packet.payload.decodePayload(T.self))
    }

    private static func authResponseBody(accessToken: String, refreshToken: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "accessToken": accessToken,
                "expiresIn": 600,
                "refreshToken": refreshToken,
                "refreshExpiresIn": 30 * 24 * 60 * 60,
                "user": [
                    "id": userID.uuidString,
                    "email": "tester@example.com"
                ]
            ]
        )
    }
}
