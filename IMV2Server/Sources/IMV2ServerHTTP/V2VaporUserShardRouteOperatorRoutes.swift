import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 用户分片路由切换请求体。
///
/// - Parameters:
///   - operationID: 幂等操作 ID。
///   - userID: 用户 ID。
///   - expectedRouterEpoch: 预期路由 epoch。
///   - writeBucket: 新写入分片。
///   - readFallbackBucket: 读回退分片（可选）。
public struct V2UserShardRouteCutoverHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let expectedRouterEpoch: Int64
    public let writeBucket: String
    public let readFallbackBucket: String?

    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64, writeBucket: String, readFallbackBucket: String?) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
        self.writeBucket = writeBucket
        self.readFallbackBucket = readFallbackBucket
    }

    func command() throws -> V2UserShardRouteCutover {
        try .init(
            operationID: operationID,
            userID: try UserID(userID),
            expectedRouterEpoch: expectedRouterEpoch,
            newWriteBucket: writeBucket,
            readFallbackBucket: readFallbackBucket
        )
    }
}

/// 切换操作响应体。
public struct V2UserShardRouteCutoverHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let writeBucket: String
    public let routerEpoch: Int64
    public let readFallbackBucket: String?
    public let wasIdempotent: Bool
}

/// 回滚请求体。
public struct V2UserShardRouteRollbackHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let expectedRouterEpoch: Int64

    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
    }

    func command() throws -> V2UserShardRouteRollback {
        try .init(operationID: operationID, userID: try UserID(userID), expectedRouterEpoch: expectedRouterEpoch)
    }
}

/// 用户分片路由操作员端点（切换与回滚）。
///
/// 仅允许处理预校验后的单用户切换，禁止批量迁移、SQL、物理位置信息曝光。
/// 外层 operator 进程为环回 + bearer 授权模式。
public struct V2VaporUserShardRouteOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let control: any V2UserShardRouteCutoverHandling & V2UserShardRouteRollbackHandling

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员鉴权器。
    ///   - control: 切换/回滚执行器。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, control: any V2UserShardRouteCutoverHandling & V2UserShardRouteRollbackHandling) {
        self.authenticator = authenticator
        self.control = control
    }

    /// 挂载：
    /// - `POST /internal/v2/user-shard-routes/cutover`
    /// - `POST /internal/v2/user-shard-routes/rollback`
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "user-shard-routes", "cutover") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2UserShardRouteCutover
            do { command = try request.content.decode(V2UserShardRouteCutoverHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2UserShardRouteCutoverResult
            do { result = try await control.cutOver(command) }
            catch V2UserShardRouteControlError.operationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.staleRouterEpoch { throw Abort(.conflict) }
            catch is V2UserShardRouterError { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            let body = try JSONEncoder().encode(V2UserShardRouteCutoverHTTPResponse(
                operationID: command.operationID,
                writeBucket: result.route.bucket,
                routerEpoch: result.route.observedRouterEpoch,
                readFallbackBucket: result.route.readFallbackBucket,
                wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: body))
        }
        routes.post("internal", "v2", "user-shard-routes", "rollback") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2UserShardRouteRollback
            do { command = try request.content.decode(V2UserShardRouteRollbackHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2UserShardRouteCutoverResult
            do { result = try await control.rollBack(command) }
            catch V2UserShardRouteControlError.operationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.staleRouterEpoch { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.migrationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.migrationNotVerified { throw Abort(.conflict) }
            catch is V2UserShardRouterError { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            let body = try JSONEncoder().encode(V2UserShardRouteCutoverHTTPResponse(
                operationID: command.operationID, writeBucket: result.route.bucket,
                routerEpoch: result.route.observedRouterEpoch,
                readFallbackBucket: result.route.readFallbackBucket, wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: body))
        }
    }
}
