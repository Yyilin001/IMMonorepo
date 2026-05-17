@testable import IMServer
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
import Vapor
import VaporTesting

extension IMServerTests {
    @Test("Two TCP devices receive canonical message echo when one device sends")
    func twoTCPDevicesReceiveCanonicalMessageEchoFromSender() async throws {
        try await withApp(configure: { app in
            try await configure(app)
            app.imTCPConfiguration = IMTCPConfiguration(
                enabled: true,
                host: "127.0.0.1",
                port: 0,
                protocolVersion: 1,
                authTimeout: 2,
                heartbeatInterval: 30,
                idleTimeout: 90,
                maxFrameBytes: 64 * 1024
            )
        }) { app in
            let tcpServer = try await startTestIMTCPServer(app: app)
            defer { Task { try? await tcpServer.channel.close().get() } }

            let deviceAAccessToken = try await loginAccessToken(
                email: loginRequest.email,
                password: loginRequest.password,
                deviceID: "tcp-device-a",
                on: app
            )
            let deviceBAccessToken = try await loginAccessToken(
                email: loginRequest.email,
                password: loginRequest.password,
                deviceID: "tcp-device-b",
                on: app
            )
            let peerUser = try await makeUser(email: "tcp-mirror-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: deviceAAccessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "TCP Mirror",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)

            let deviceA = try await IMTCPTestClient.connect(port: tcpServer.port, eventLoopGroup: app.eventLoopGroup)
            let deviceB = try await IMTCPTestClient.connect(port: tcpServer.port, eventLoopGroup: app.eventLoopGroup)
            defer {
                Task {
                    await deviceA.close()
                    await deviceB.close()
                }
            }

            try await deviceA.authenticate(accessToken: deviceAAccessToken, deviceID: "tcp-device-a")
            try await deviceB.authenticate(accessToken: deviceBAccessToken, deviceID: "tcp-device-b")

            let requestID = UUID()
            let clientMessageID = "tcp-client-message-1"
            try await deviceA.send(
                type: .message,
                requestID: requestID,
                payload: imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: clientMessageID,
                    text: "hello from tcp device a"
                )
            )

            let ackPacket = try await deviceA.nextPacket(ofType: .ack)
            let acknowledgement = try ackPacket.payload.decodePayload(IMTCPAckPayload.self)
            #expect(ackPacket.requestID == requestID)
            #expect(acknowledgement.status == "accepted")
            #expect(acknowledgement.conversationID == conversationID.uuidString)

            let deviceAMessage = try await deviceA.nextPacket(ofType: .message)
                .payload.decodePayload(IMTCPMessagePayload.self)
            let deviceBMessage = try await deviceB.nextPacket(ofType: .message)
                .payload.decodePayload(IMTCPMessagePayload.self)

            #expect(deviceAMessage.clientMessageID == clientMessageID)
            #expect(deviceBMessage.clientMessageID == clientMessageID)
            #expect(deviceAMessage.messageID == acknowledgement.messageID)
            #expect(deviceBMessage.messageID == acknowledgement.messageID)
            #expect(deviceAMessage.serverSequence == 1)
            #expect(deviceBMessage.serverSequence == 1)
            #expect(deviceAMessage.body["text"] == "hello from tcp device a")
            #expect(deviceBMessage.body["text"] == "hello from tcp device a")
        }
    }

    @Test("TCP auth rejects a device ID that does not match the access-token session")
    func tcpAuthRejectsMismatchedDeviceID() async throws {
        try await withApp(configure: configure) { app in
            var accessToken = ""

            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            let authenticator = IMTCPAuthenticator(app: app, db: app.db)
            do {
                _ = try await authenticator.authenticate(
                    accessToken: accessToken,
                    remoteIPAddress: nil,
                    deviceID: "different-device",
                    deviceName: "Different Device",
                    platform: "ios",
                    appVersion: "1.0"
                )
                Issue.record("Expected TCP auth to reject a mismatched device ID")
            } catch {
                // Expected: TCP auth must not allow clients to spoof the device identity for a session.
            }

            let connection = try await authenticator.authenticate(
                accessToken: accessToken,
                remoteIPAddress: nil,
                deviceID: "simulator",
                deviceName: "Test Device",
                platform: "ios",
                appVersion: "1.0"
            )
            #expect(connection.deviceID == "simulator")
        }
    }

    @Test("Binding a second TCP connection for the same session replaces the old connection")
    func bindingSecondTCPConnectionForSameSessionReplacesOldConnection() async throws {
        try await withApp(configure: configure) { app in
            let userID = UUID()
            let sessionID = UUID()
            let firstConnectionID = UUID()
            let secondConnectionID = UUID()
            let firstChannel = EmbeddedChannel()
            let secondChannel = EmbeddedChannel()
            let firstConnection = IMAuthenticatedConnection(
                connectionID: firstConnectionID,
                userID: userID,
                sessionID: sessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )
            let secondConnection = IMAuthenticatedConnection(
                connectionID: secondConnectionID,
                userID: userID,
                sessionID: sessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )

            try await app.gatewaySessionService.bind(
                firstConnection,
                control: IMConnectionControl(connectionID: firstConnectionID, channel: firstChannel)
            )
            #expect(await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [sessionID])[sessionID] == 1)

            try await app.gatewaySessionService.bind(
                secondConnection,
                control: IMConnectionControl(connectionID: secondConnectionID, channel: secondChannel)
            )

            #expect(await app.imConnectionRegistry.authenticatedConnection(for: firstConnectionID)?.connectionID == nil)
            #expect(await app.imConnectionRegistry.authenticatedConnection(for: secondConnectionID)?.connectionID == secondConnectionID)
            #expect(await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: [sessionID])[sessionID] == 1)

            await app.gatewaySessionService.remove(connectionID: secondConnectionID)
        }
    }

    @Test("Gateway relay session-counts returns local active session counts")
    func gatewayRelaySessionCountsReturnsLocalCounts() async throws {
        try await withApp(configure: configure) { app in
            let userID = UUID()
            let activeSessionID = UUID()
            let inactiveSessionID = UUID()
            let connectionID = UUID()
            let channel = EmbeddedChannel()
            let connection = IMAuthenticatedConnection(
                connectionID: connectionID,
                userID: userID,
                sessionID: activeSessionID,
                authenticatedAt: Date(),
                remoteIPAddress: "127.0.0.1",
                deviceID: "device-a",
                deviceName: "Device A",
                platform: "ios",
                appVersion: "1.0"
            )
            let control = IMConnectionControl(connectionID: connectionID, channel: channel)
            try await app.gatewaySessionService.bind(connection, control: control)

            try await app.testing().test(.POST, "internal/gateway/realtime/session-counts", beforeRequest: { req in
                try req.content.encode(GatewayRelaySessionCountsRequest(sessionIDs: [activeSessionID, inactiveSessionID]))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(GatewayRelaySessionCountsResponse.self)
                #expect(response.counts[activeSessionID] == 1)
                #expect(response.counts[inactiveSessionID] == 0)
            })

            await app.gatewaySessionService.remove(connectionID: connectionID)
        }
    }

    @Test("Connection routing fans out user packets only to routed remote nodes")
    func connectionRoutingFansOutUserPacketsToRoutedRemoteNodes() async throws {
        let app = try await Application.make(.testing)
        app.imNodeID = "node-a"

        let userID = UUID()
        let presenceStore = FakePresenceStore()
        await presenceStore.setUserRoutes([userID: ["node-a", "node-b"]])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        let payload = IMTCPMessagePayload(
            clientMessageID: "client-1",
            messageID: "server-1",
            conversationID: UUID().uuidString,
            senderUserID: userID,
            serverSequence: 1,
            serverTimestamp: Date(),
            content: .text("hello")
        )
        await routingService.sendMessage(payload, toUserIDs: [userID], requestID: UUID())

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .message)
        #expect(dispatches.first?.envelope.targetUserIDs == [userID])

        try await app.asyncShutdown()
    }

    @Test("Connection routing kicks only routed remote sessions")
    func connectionRoutingKicksOnlyRoutedRemoteSessions() async throws {
        let app = try await Application.make(.testing)
        app.imNodeID = "node-a"

        let localSessionID = UUID()
        let remoteSessionID = UUID()
        let presenceStore = FakePresenceStore()
        await presenceStore.setSessionRoutes([
            localSessionID: ["node-a"],
            remoteSessionID: ["node-b"]
        ])
        let dispatchService = FakeNodeMessageDispatchService()
        let routingService = ConnectionRoutingService(
            app: app,
            backend: FakeConnectionRoutingBackend(
                presenceStore: presenceStore,
                dispatchService: dispatchService
            )
        )

        await routingService.kickConnections(
            forSessionID: remoteSessionID,
            reason: .sessionRevoked,
            message: "Session revoked"
        )

        let dispatches = await dispatchService.dispatches()
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.nodeID == "node-b")
        #expect(dispatches.first?.envelope.action == .kickSession)
        #expect(dispatches.first?.envelope.sessionID == remoteSessionID)

        try await app.asyncShutdown()
    }
}

private struct FakeConnectionRoutingBackend: ConnectionRoutingBackend {
    let backendName = "fake"
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    func start(app: Application) async throws {}
    func shutdown() async {}
}

private struct IMTCPTestServer: Sendable {
    let channel: any Channel
    let port: Int
}

private func startTestIMTCPServer(app: Application) async throws -> IMTCPTestServer {
    let configuration = app.imTCPConfiguration
    let channel = try await ServerBootstrap(group: app.eventLoopGroup)
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(
                ByteToMessageHandler(
                    IMTCPLineFrameDecoder(maxFrameBytes: configuration.maxFrameBytes)
                )
            )
            .flatMap {
                channel.pipeline.addHandler(IMTCPConnectionHandler(application: app))
            }
        }
        .bind(host: configuration.host, port: configuration.port)
        .get()

    guard let port = channel.localAddress?.port else {
        throw IMTCPTestFailure.missingBoundPort
    }
    return IMTCPTestServer(channel: channel, port: port)
}

private struct IMTCPTestClient: Sendable {
    let channel: any Channel
    let inbox: IMTCPTestInbox

    static func connect(port: Int, eventLoopGroup: any EventLoopGroup) async throws -> IMTCPTestClient {
        let inbox = IMTCPTestInbox()
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    ByteToMessageHandler(
                        IMTCPLineFrameDecoder(maxFrameBytes: 64 * 1024)
                    )
                )
                .flatMap {
                    channel.pipeline.addHandler(IMTCPTestClientHandler(inbox: inbox))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        return IMTCPTestClient(channel: channel, inbox: inbox)
    }

    func authenticate(accessToken: String, deviceID: String) async throws {
        try await send(
            type: .auth,
            requestID: UUID(),
            payload: IMTCPAuthRequestPayload(
                accessToken: accessToken,
                deviceID: deviceID,
                deviceName: "Test \(deviceID)",
                platform: "ios",
                appVersion: "1.0",
                protocolVersion: 1
            )
        )
        _ = try await nextPacket(ofType: .authOK)
    }

    func send<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        requestID: UUID? = nil,
        payload: Payload
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let envelope = IMTCPPacketEnvelope(type: type, requestID: requestID, payload: payload)
        let data = try encoder.encode(envelope)
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeInteger(UInt8(ascii: "\n"))
        try await channel.writeAndFlush(buffer).get()
    }

    func nextPacket(ofType type: IMTCPPacketType) async throws -> IMTCPInboundPacket {
        try await inbox.nextPacket(ofType: type)
    }

    func close() async {
        try? await channel.close().get()
    }
}

private final class IMTCPTestClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = String

    private let inbox: IMTCPTestInbox

    init(inbox: IMTCPTestInbox) {
        self.inbox = inbox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = line.data(using: .utf8),
              let packet = try? decoder.decode(IMTCPInboundPacket.self, from: payload)
        else {
            return
        }

        Task {
            await inbox.append(packet)
        }
    }
}

private actor IMTCPTestInbox {
    private var packets: [IMTCPInboundPacket] = []

    func append(_ packet: IMTCPInboundPacket) {
        packets.append(packet)
    }

    func nextPacket(ofType type: IMTCPPacketType) async throws -> IMTCPInboundPacket {
        let timeout: UInt64 = 2_000_000_000
        let pollInterval: UInt64 = 10_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let index = packets.firstIndex(where: { $0.type == type }) {
                return packets.remove(at: index)
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        throw IMTCPTestFailure.packetTimeout(type)
    }
}

private enum IMTCPTestFailure: Error {
    case missingBoundPort
    case packetTimeout(IMTCPPacketType)
}

private actor FakePresenceStore: PresenceStore {
    nonisolated let backendName = "fake-presence"

    private var userRoutes: [UUID: Set<String>] = [:]
    private var sessionRoutes: [UUID: Set<String>] = [:]

    func setUserRoutes(_ routes: [UUID: Set<String>]) {
        userRoutes = routes
    }

    func setSessionRoutes(_ routes: [UUID: Set<String>]) {
        sessionRoutes = routes
    }

    func start(app: Application) async throws {}
    func shutdown() async {}
    func activatePresence(forUserID userID: UUID) async throws {}
    func deactivatePresence(forUserID userID: UUID) async throws {}
    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}
    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        Dictionary(uniqueKeysWithValues: userIDs.map { ($0, userRoutes[$0] ?? []) })
    }

    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] {
        Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, sessionRoutes[$0] ?? []) })
    }

    func activeNodeIDs() async throws -> Set<String> {
        Set(userRoutes.values.flatMap { $0 }).union(sessionRoutes.values.flatMap { $0 })
    }
}

private actor FakeNodeMessageDispatchService: NodeMessageDispatchService {
    struct Dispatch: Sendable {
        let envelope: NodeMessageDispatchEnvelope
        let nodeID: String
    }

    private var recordedDispatches: [Dispatch] = []

    func start(app: Application) async throws {}
    func shutdown() async {}

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        recordedDispatches.append(Dispatch(envelope: envelope, nodeID: nodeID))
    }

    func dispatches() -> [Dispatch] {
        recordedDispatches
    }
}
