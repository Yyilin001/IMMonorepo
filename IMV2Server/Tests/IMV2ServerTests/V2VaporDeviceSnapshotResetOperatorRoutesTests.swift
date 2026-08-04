import Foundation
import IMV2Core
import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device snapshot-reset operator routes")
struct V2VaporDeviceSnapshotResetOperatorRoutesTests {
    @Test("operator reset is bearer-gated, no-store, and forwards one durable command")
    func stagesReset() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 0x41, count: 32).base64EncodedString()
        let userID = try UserID("00000000-0000-0000-0000-000000000851")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000852")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000853")!
        let service = SnapshotResetRouteService()
        V2VaporDeviceSnapshotResetOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: service
        ).register(on: app)

        try await app.testing().test(.POST, "internal/v2/device-snapshots/reset", beforeRequest: { request in
            request.headers.bearerAuthorization = .init(token: token)
            try request.content.encode(V2DeviceSnapshotResetHTTPRequest(operationID: operationID, userID: userID.rawValue, deviceID: deviceID.rawValue))
        }) { response async in
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .cacheControl) == "no-store")
            var decoded: V2DeviceSnapshotResetHTTPResponse?
            expectContent(V2DeviceSnapshotResetHTTPResponse.self, response) { decoded = $0 }
            #expect(decoded == .init(operationID: operationID, generation: 3, wasIdempotent: false))
        }
        let command = try #require(await service.command())
        #expect(command.userID == userID)
        #expect(command.deviceID == deviceID)
        #expect(command.operationID == operationID)
    }

    @Test("reset rejects malformed and unauthorized requests before staging")
    func rejectsInvalidRequests() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let token = Data(repeating: 0x42, count: 32).base64EncodedString()
        let service = SnapshotResetRouteService()
        V2VaporDeviceSnapshotResetOperatorRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
        try await app.testing().test(.POST, "internal/v2/device-snapshots/reset") { response async in
            #expect(response.status == .unauthorized)
        }
        #expect(await service.command() == nil)
    }
}

private actor SnapshotResetRouteService: V2DeviceSnapshotResetting {
    private var received: V2DeviceSnapshotResetCommand?
    func stage(_ command: V2DeviceSnapshotResetCommand) -> V2DeviceSnapshotResetResult {
        received = command
        return .init(generation: 3, wasIdempotent: false)
    }
    func command() -> V2DeviceSnapshotResetCommand? { received }
}
