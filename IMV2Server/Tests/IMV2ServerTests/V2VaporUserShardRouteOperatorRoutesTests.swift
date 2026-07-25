import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor user-shard route operator routes")
struct V2VaporUserShardRouteOperatorRoutesTests {
    @Test("authorized single-user cutover is no-store and forwards only the bounded command")
    func authorizedCutover() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 12, count: 32).base64EncodedString()
        let control = RouteControlFake()
        V2VaporUserShardRouteOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), control: control
        ).register(on: app)
        let request = V2UserShardRouteCutoverHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            userID: "00000000-0000-0000-0000-000000000902",
            expectedRouterEpoch: 7,
            writeBucket: "users-b",
            readFallbackBucket: "users-a"
        )
        try await app.testing().test(.POST, "internal/v2/user-shard-routes/cutover", headers: ["Authorization": "Bearer \(token)"], beforeRequest: {
            try $0.content.encode(request)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var decoded: V2UserShardRouteCutoverHTTPResponse?
            expectContent(V2UserShardRouteCutoverHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.operationID == request.operationID)
            #expect(decoded?.writeBucket == "users-b")
            #expect(decoded?.routerEpoch == 8)
            #expect(decoded?.readFallbackBucket == "users-a")
            #expect(decoded?.wasIdempotent == false)
        }
        let command = try #require(await control.commands().first)
        #expect(command.expectedRouterEpoch == 7)
        #expect(command.newWriteBucket == "users-b")
    }

    @Test("route rejects unauthorized and malformed cutovers before invoking control")
    func rejectsInvalidRequests() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 13, count: 32).base64EncodedString()
        let control = RouteControlFake()
        V2VaporUserShardRouteOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), control: control
        ).register(on: app)
        let invalid = V2UserShardRouteCutoverHTTPRequest(
            operationID: UUID(), userID: "00000000-0000-0000-0000-000000000903", expectedRouterEpoch: 0,
            writeBucket: "users-b", readFallbackBucket: "users-b"
        )
        try await app.testing().test(.POST, "internal/v2/user-shard-routes/cutover", beforeRequest: {
            try $0.content.encode(invalid)
        }) { #expect($0.status == .unauthorized) }
        try await app.testing().test(.POST, "internal/v2/user-shard-routes/cutover", headers: ["Authorization": "Bearer \(token)"], beforeRequest: {
            try $0.content.encode(invalid)
        }) { #expect($0.status == .badRequest) }
        #expect(await control.commands().isEmpty)
    }

    @Test("rollback is authenticated, no-store and contains no caller-selected bucket")
    func rollsBackOneRetainedUser() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 15, count: 32).base64EncodedString()
        let control = RouteControlFake()
        V2VaporUserShardRouteOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), control: control
        ).register(on: app)
        let request = V2UserShardRouteRollbackHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
            userID: "00000000-0000-0000-0000-000000000905", expectedRouterEpoch: 8
        )
        try await app.testing().test(.POST, "internal/v2/user-shard-routes/rollback", headers: ["Authorization": "Bearer \(token)"], beforeRequest: {
            try $0.content.encode(request)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var decoded: V2UserShardRouteCutoverHTTPResponse?
            expectContent(V2UserShardRouteCutoverHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.writeBucket == "users-a")
            #expect(decoded?.readFallbackBucket == "users-b")
        }
        #expect((try #require(await control.rollbacks().first)).expectedRouterEpoch == 8)
    }
}

private actor RouteControlFake: V2UserShardRouteCutoverHandling, V2UserShardRouteRollbackHandling {
    private var received: [V2UserShardRouteCutover] = []
    private var receivedRollbacks: [V2UserShardRouteRollback] = []

    func cutOver(_ command: V2UserShardRouteCutover) throws -> V2UserShardRouteCutoverResult {
        received.append(command)
        return .init(route: try .init(bucket: command.newWriteBucket, observedRouterEpoch: command.expectedRouterEpoch + 1, readFallbackBucket: command.readFallbackBucket), wasIdempotent: false)
    }

    func commands() -> [V2UserShardRouteCutover] { received }
    func rollBack(_ command: V2UserShardRouteRollback) throws -> V2UserShardRouteCutoverResult {
        receivedRollbacks.append(command)
        return .init(route: try .init(bucket: "users-a", observedRouterEpoch: command.expectedRouterEpoch + 1, readFallbackBucket: "users-b"), wasIdempotent: false)
    }
    func rollbacks() -> [V2UserShardRouteRollback] { receivedRollbacks }
}
