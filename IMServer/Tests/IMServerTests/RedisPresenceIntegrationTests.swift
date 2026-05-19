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

    @Test("Redis AI stream lease enforces distributed limits and cancellation")
    func redisAIStreamLeaseEnforcesDistributedLimitsAndCancellation() async throws {
        guard let redisURL = Environment.get("IM_REDIS_INTEGRATION_URL"), !redisURL.isEmpty else {
            return
        }

        let suffix = UUID().uuidString.lowercased()
        let nodeA = "redis-ai-stream-a-\(suffix)"
        let nodeB = "redis-ai-stream-b-\(suffix)"
        let configuration = IMRedisRoutingConfiguration(
            url: redisURL,
            mode: .redis,
            maximumConnectionCount: 2
        )
        let appA = try await Application.make(.testing)
        let appB = try await Application.make(.testing)
        let storeA = try RedisAIStreamLeaseStore(
            configuration: configuration,
            nodeID: nodeA,
            logger: appA.logger,
            eventLoop: appA.eventLoopGroup.next()
        )
        let storeB = try RedisAIStreamLeaseStore(
            configuration: configuration,
            nodeID: nodeB,
            logger: appB.logger,
            eventLoop: appB.eventLoopGroup.next()
        )

        do {
            try await storeA.start(app: appA)
            try await storeB.start(app: appB)

            let userID = UUID()
            let conversationID = UUID()
            let firstStreamID = UUID().uuidString
            let secondStreamID = UUID().uuidString

            try await storeA.reserve(streamID: firstStreamID, conversationID: conversationID, userID: userID)
            try await storeB.reserve(streamID: secondStreamID, conversationID: conversationID, userID: userID)
            await #expect(throws: Abort.self) {
                try await storeA.reserve(streamID: UUID().uuidString, conversationID: conversationID, userID: userID)
            }

            var counts = try await storeB.activeCounts(conversationID: conversationID, userID: userID)
            #expect(counts.userCount == 2)
            #expect(counts.conversationCount == 2)

            try await storeB.requestCancel(streamID: firstStreamID)
            #expect(try await storeA.cancelRequested(streamID: firstStreamID))
            #expect(try await storeA.heartbeat(streamID: firstStreamID, conversationID: conversationID, userID: userID))

            try await storeA.finish(streamID: firstStreamID, conversationID: conversationID, userID: userID)
            #expect(try await !storeB.isActive(streamID: firstStreamID))
            counts = try await storeB.activeCounts(conversationID: conversationID, userID: userID)
            #expect(counts.userCount == 1)
            #expect(counts.conversationCount == 1)

            let conversationLimitID = UUID()
            for _ in 0..<5 {
                try await storeA.reserve(streamID: UUID().uuidString, conversationID: conversationLimitID, userID: UUID())
            }
            await #expect(throws: Abort.self) {
                try await storeB.reserve(streamID: UUID().uuidString, conversationID: conversationLimitID, userID: UUID())
            }

            await storeB.shutdown()
            await storeA.shutdown()
            try await appB.asyncShutdown()
            try await appA.asyncShutdown()
        } catch {
            await storeB.shutdown()
            await storeA.shutdown()
            try? await appB.asyncShutdown()
            try? await appA.asyncShutdown()
            throw error
        }
    }
}
