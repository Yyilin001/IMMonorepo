import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor device snapshot-reset operator routes")
struct V2VaporDeviceSnapshotResetOperatorRoutesTests {
    @Test("operator reset is bearer-gated, no-store, and forwards one durable command")
    func stagesReset() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 0x41, count: 32).base64EncodedString()
        let userID = try UserID("00000000-0000-0000-0000-000000000851")
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000852")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000853")!
        let service = SnapshotResetRouteService()
        V2VaporDeviceSnapshotResetOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token),
            service: service
        ).register(on: app)

        try await app.testing { client in
            let response = try await client.send(.post, to: "internal/v2/device-snapshots/reset", beforeSend: { request in
            request.headers.bearerAuthorization = .init(token: token)
            try request.content.encode(V2DeviceSnapshotResetHTTPRequest(operationID: operationID, userID: userID.rawValue, deviceID: deviceID.rawValue))
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            var decoded: V2DeviceSnapshotResetHTTPResponse?
            decoded = try await response.content.decode(V2DeviceSnapshotResetHTTPResponse.self)
            #expect(decoded == .init(operationID: operationID, generation: 3, state: .preparing, wasIdempotent: false))
        }
        let command = try #require(await service.command())
        #expect(command.userID == userID)
        #expect(command.deviceID == deviceID)
        #expect(command.operationID == operationID)
    }

    @Test("reset rejects malformed and unauthorized requests before staging")
    func rejectsInvalidRequests() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 0x42, count: 32).base64EncodedString()
        let service = SnapshotResetRouteService()
        V2VaporDeviceSnapshotResetOperatorRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
        try await app.testing { client in
            let response = try await client.send(.post, to: "internal/v2/device-snapshots/reset")
            #expect(response.status == .unauthorized)
        }
        #expect(await service.command() == nil)
    }
}

private actor SnapshotResetRouteService: V2DeviceSnapshotResetting {
    private var received: V2DeviceSnapshotResetCommand?
    func stage(_ command: V2DeviceSnapshotResetCommand) -> V2DeviceSnapshotResetResult {
        received = command
        return .init(generation: 3, state: .preparing, wasIdempotent: false)
    }
    func command() -> V2DeviceSnapshotResetCommand? { received }
}
