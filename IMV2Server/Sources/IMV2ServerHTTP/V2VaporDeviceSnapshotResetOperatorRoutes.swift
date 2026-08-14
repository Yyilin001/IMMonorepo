import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2DeviceSnapshotResetHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let deviceID: String
    public init(operationID: UUID, userID: String, deviceID: String) { self.operationID = operationID; self.userID = userID; self.deviceID = deviceID }
    func command() throws -> V2DeviceSnapshotResetCommand {
        try .init(operationID: operationID, userID: .init(userID), deviceID: .init(deviceID))
    }
}

public struct V2DeviceSnapshotResetHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let generation: UInt64
    public let state: V2DeviceSnapshotResetBuildState
    public let wasIdempotent: Bool
}

/// Recovery-only endpoint for staging one server-built snapshot. It runs only
/// on the loopback operator service and shares its dedicated bearer boundary.
public struct V2VaporDeviceSnapshotResetOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2DeviceSnapshotResetting

    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2DeviceSnapshotResetting) {
        self.authenticator = authenticator
        self.service = service
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "device-snapshots", "reset") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else { throw Abort(.unauthorized) }
            let command: V2DeviceSnapshotResetCommand
            do { command = try request.content.decode(V2DeviceSnapshotResetHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2DeviceSnapshotResetResult
            do { result = try await service.stage(command) }
            catch V2DeviceSnapshotResetError.deviceUnavailable { throw Abort(.notFound) }
            catch V2DeviceSnapshotResetError.resetAlreadyPending { throw Abort(.conflict) }
            catch { throw Abort(.serviceUnavailable) }
            let data = try JSONEncoder().encode(V2DeviceSnapshotResetHTTPResponse(operationID: command.operationID, generation: result.generation, state: result.state, wasIdempotent: result.wasIdempotent))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: data))
        }
    }
}
