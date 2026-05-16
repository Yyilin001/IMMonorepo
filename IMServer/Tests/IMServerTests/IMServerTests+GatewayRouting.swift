@testable import IMServer
import Foundation
import NIOEmbedded
import Testing
import Vapor
import VaporTesting

extension IMServerTests {
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
