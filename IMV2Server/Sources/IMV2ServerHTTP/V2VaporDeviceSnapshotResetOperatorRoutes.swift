import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 设备快照重置请求体。
///
/// - Parameters:
///   - operationID: 幂等操作标识。
///   - userID: 目标用户。
///   - deviceID: 目标设备。
public struct V2DeviceSnapshotResetHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let deviceID: String
    public init(operationID: UUID, userID: String, deviceID: String) { self.operationID = operationID; self.userID = userID; self.deviceID = deviceID }
    func command() throws -> V2DeviceSnapshotResetCommand {
        try .init(operationID: operationID, userID: .init(userID), deviceID: .init(deviceID))
    }
}

/// 设备快照重置响应体。
///
/// - Parameters:
///   - operationID: 当前操作 ID。
///   - generation: 快照代次数。
///   - state: 构建状态。
///   - wasIdempotent: 是否幂等复用结果。
public struct V2DeviceSnapshotResetHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let generation: UInt64
    public let state: V2DeviceSnapshotResetBuildState
    public let wasIdempotent: Bool
}

/// 仅面向恢复流程的快照重置路由。
///
/// 运行在 operator 回放服务，并使用环回专用的 bearer 鉴权边界。
/// 每次调用仅允许触发一次快照重置阶段。
public struct V2VaporDeviceSnapshotResetOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2DeviceSnapshotResetting

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员 bearer 鉴权器。
    ///   - service: 设备快照重置服务。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2DeviceSnapshotResetting) {
        self.authenticator = authenticator
        self.service = service
    }

    /// 挂载 `POST /internal/v2/device-snapshots/reset`。
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
