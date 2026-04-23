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
            protocolVersion: 1,
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

        let authLine = try await requireRecordedLine(at: 0, from: wire)
        let authPacket = try decode(IMTCPPacketEnvelope<IMTCPAuthRequestPayload>.self, from: authLine)
        #expect(authPacket.type == .auth)
        #expect(authPacket.payload.accessToken == "access-123")
        #expect(authPacket.payload.deviceID == "device-1")
        #expect(authPacket.payload.deviceName == "iPhone")
        #expect(authPacket.payload.platform == "ios")
        #expect(authPacket.payload.appVersion == "1.0.0")
        #expect(authPacket.payload.protocolVersion == 1)

        await wire.yieldIncoming(
            try encodeLine(
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

    @Test func heartbeatMessageConversationEventAndKickAreDeliveredAsEvents() async throws {
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

        _ = try await requireRecordedLine(at: 0, from: wire)

        await wire.yieldIncoming(
            try encodeLine(
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
        let heartbeatLine = try await requireRecordedLine(at: 1, from: wire)
        let heartbeatPacket = try decode(IMTCPPacketEnvelope<IMTCPHeartbeatPayload>.self, from: heartbeatLine)
        #expect(heartbeatPacket.type == .heartbeat)
        #expect(heartbeatPacket.requestID == heartbeatRequestID)
        #expect(heartbeatPacket.payload.sequence == 7)

        await wire.yieldIncoming(
            try encodeLine(
                type: .heartbeatAck,
                requestID: heartbeatRequestID,
                payload: IMTCPHeartbeatPayload(sequence: 7)
            )
        )

        let heartbeatEvent = try await iterator.next()
        #expect(heartbeatEvent == .heartbeatAck(requestID: heartbeatRequestID, payload: IMTCPHeartbeatPayload(sequence: 7)))

        let messageRequestID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let messagePayload = IMTCPMessagePayload(
            clientMessageID: nil,
            messageID: "srv-msg-1",
            conversationID: "conv-42",
            senderUserID: Self.userID,
            serverSequence: 7,
            serverTimestamp: Date(timeIntervalSince1970: 1_700_000_101),
            kind: "text",
            body: ["text": "hello"]
        )

        await wire.yieldIncoming(
            try encodeLine(
                type: .message,
                requestID: messageRequestID,
                payload: messagePayload
            )
        )

        let messageEvent = try await iterator.next()
        #expect(messageEvent == .message(requestID: messageRequestID, payload: messagePayload))

        let conversationRequestID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let conversationEventPayload = IMTCPConversationEventPayload(
            eventType: .summaryUpdated,
            conversation: IMConversationSummaryResponseBody(
                id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
                title: "Realtime Conversation",
                memberUserIDs: [Self.userID],
                lastMessage: IMMessagePreviewResponseBody(
                    id: UUID(uuidString: "13131313-3434-5656-7878-909090909090")!,
                    senderUserID: Self.userID,
                    serverSequence: 8,
                    kind: "text",
                    body: ["text": "summary update"],
                    createdAt: Date(timeIntervalSince1970: 1_700_000_102)
                ),
                lastReadSequence: 8,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_102)
            ),
            actorUserID: Self.userID,
            serverTimestamp: Date(timeIntervalSince1970: 1_700_000_102)
        )

        await wire.yieldIncoming(
            try encodeLine(
                type: .conversationEvent,
                requestID: conversationRequestID,
                payload: conversationEventPayload
            )
        )

        let conversationEvent = try await iterator.next()
        #expect(conversationEvent == .conversationEvent(requestID: conversationRequestID, payload: conversationEventPayload))

        await wire.yieldIncoming(
            try encodeLine(
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

        _ = try await requireRecordedLine(at: 0, from: wire)

        await wire.yieldIncoming(
            try encodeLine(
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

        let ackLine = try await requireRecordedLine(at: 1, from: wire)
        let ackPacket = try decode(IMTCPPacketEnvelope<IMTCPAckPayload>.self, from: ackLine)
        #expect(ackPacket.type == .ack)
        #expect(ackPacket.requestID == requestID)
        #expect(ackPacket.payload.messageID == "srv-msg-2")
        #expect(ackPacket.payload.conversationID == "conv-100")
        #expect(ackPacket.payload.status == "received")
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

        let authLine = try await requireRecordedLine(at: 0, from: wire)
        let authPacket = try decode(IMTCPPacketEnvelope<IMTCPAuthRequestPayload>.self, from: authLine)
        #expect(authPacket.payload.accessToken == "tcp-access")

        await wire.yieldIncoming(
            try encodeLine(
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

    private func requireRecordedLine(at index: Int, from wire: MockIMTCPWire) async throws -> String {
        for _ in 0..<50 {
            let lines = await wire.recordedLines()
            if lines.indices.contains(index) {
                return lines[index]
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待第 \(index) 条 TCP 发送数据超时。")
        throw IMTCPClientError.connectionClosed
    }

    private func encodeLine<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        requestID: UUID? = nil,
        payload: Payload
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            IMTCPPacketEnvelope(type: type, requestID: requestID, payload: payload)
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
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
