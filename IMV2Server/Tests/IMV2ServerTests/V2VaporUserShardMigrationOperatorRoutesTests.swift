import Foundation
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor user-shard migration operator routes")
struct V2VaporUserShardMigrationOperatorRoutesTests {
    @Test("copy verify route is authenticated, one-user and no-store")
    func invokesBoundedService() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 14, count: 32).base64EncodedString()
        let request = V2UserShardMigrationCopyVerifyHTTPRequest(
            migrationID: UUID(uuidString: "00000000-0000-0000-0000-000000000981")!,
            userID: "00000000-0000-0000-0000-000000000982", sourceBucket: "users-a",
            targetBucket: "users-b", sourceRouterEpoch: 2
        )
        let service = MigrationHTTPServiceFake()
        V2VaporUserShardMigrationOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), service: service
        ).register(on: app)
        try await app.testing().test(.POST, "internal/v2/user-shard-migrations/copy-verify", headers: ["Authorization": "Bearer \(token)"], beforeRequest: {
            try $0.content.encode(request)
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var decoded: V2UserShardMigrationCopyVerifyHTTPResponse?
            expectContent(V2UserShardMigrationCopyVerifyHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.migrationID == request.migrationID)
            #expect(decoded?.phase == .forwarding)
            #expect(decoded?.wasIdempotent == false)
        }
        #expect(await service.requests().count == 1)

        try await app.testing().test(.POST, "internal/v2/user-shard-migrations/verify-forwarding", headers: ["Authorization": "Bearer \(token)"], beforeRequest: {
            try $0.content.encode(V2UserShardMigrationForwardingVerifyHTTPRequest(migrationID: request.migrationID))
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var decoded: V2UserShardMigrationCopyVerifyHTTPResponse?
            expectContent(V2UserShardMigrationCopyVerifyHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded?.migrationID == request.migrationID)
            #expect(decoded?.phase == .verified)
            #expect(decoded?.wasIdempotent == false)
        }
    }
}

private actor MigrationHTTPServiceFake: V2UserShardMigrationCopyVerifyHandling, V2UserShardMigrationForwardingVerifyHandling {
    private var received: [V2UserShardMigrationPreparation] = []

    func prepareCopyAndVerify(_ request: V2UserShardMigrationPreparation) throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        received.append(request)
        return (.init(
            migrationID: request.migrationID, userID: request.userID, sourceBucket: request.sourceBucket,
            targetBucket: request.targetBucket, sourceRouterEpoch: request.sourceRouterEpoch, phase: .forwarding,
            sourceFingerprint: "safe", targetFingerprint: "safe"
        ), false)
    }

    func verifyForwarding(migrationID: UUID) throws -> (record: V2UserShardMigrationRecord, wasIdempotent: Bool) {
        let request = try #require(received.first { $0.migrationID == migrationID })
        return (.init(
            migrationID: request.migrationID, userID: request.userID, sourceBucket: request.sourceBucket,
            targetBucket: request.targetBucket, sourceRouterEpoch: request.sourceRouterEpoch, phase: .verified,
            sourceFingerprint: "safe", targetFingerprint: "safe"
        ), false)
    }

    func requests() -> [V2UserShardMigrationPreparation] { received }
}
