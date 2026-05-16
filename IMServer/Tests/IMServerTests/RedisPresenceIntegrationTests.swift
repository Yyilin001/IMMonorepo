@testable import IMServer
import Testing
import Vapor

@Suite("Redis presence integration tests")
struct RedisPresenceIntegrationTests {
    @Test("Redis presence routes user and session nodes when enabled")
    func redisPresenceRoutesUserAndSessionNodes() async throws {
        guard let redisURL = Environment.get("IM_REDIS_INTEGRATION_URL"), !redisURL.isEmpty else {
            return
        }

        let suffix = UUID().uuidString.lowercased()
        let nodeA = "redis-presence-a-\(suffix)"
        let nodeB = "redis-presence-b-\(suffix)"
        let configuration = IMRedisRoutingConfiguration(
            url: redisURL,
            mode: .redis,
            maximumConnectionCount: 2
        )
        let appA = try await Application.make(.testing)
        let appB = try await Application.make(.testing)
        appA.imNodeID = nodeA
        appB.imNodeID = nodeB
        let backendA = try RedisConnectionRoutingBackend(
            configuration: configuration,
            nodeID: nodeA,
            logger: appA.logger,
            eventLoop: appA.eventLoopGroup.next()
        )
        let backendB = try RedisConnectionRoutingBackend(
            configuration: configuration,
            nodeID: nodeB,
            logger: appB.logger,
            eventLoop: appB.eventLoopGroup.next()
        )

        do {
            try await backendA.start(app: appA)
            try await backendB.start(app: appB)

            let userID = UUID()
            let sessionID = UUID()
            try await backendA.presenceStore.activatePresence(forUserID: userID)
            try await backendB.presenceStore.activatePresence(forUserID: userID)
            try await backendB.presenceStore.activatePresence(forSessionID: sessionID, userID: userID)

            let userRoutes = try await backendA.presenceStore.routeNodeIDs(forUserIDs: [userID])
            let sessionRoutes = try await backendA.presenceStore.routeNodeIDs(forSessionIDs: [sessionID])
            let activeNodes = try await backendA.presenceStore.activeNodeIDs()

            #expect(userRoutes[userID]?.contains(nodeA) == true)
            #expect(userRoutes[userID]?.contains(nodeB) == true)
            #expect(sessionRoutes[sessionID] == [nodeB])
            #expect(activeNodes.contains(nodeA))
            #expect(activeNodes.contains(nodeB))

            await backendB.shutdown()
            await backendA.shutdown()
            try await appB.asyncShutdown()
            try await appA.asyncShutdown()
        } catch {
            await backendB.shutdown()
            await backendA.shutdown()
            try? await appB.asyncShutdown()
            try? await appA.asyncShutdown()
            throw error
        }
    }
}
