import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 单用户路由切换的传输请求，只携带逻辑桶，不携带物理连接配置。
///
/// 初始化保存原始字段；请求解码后再通过领域命令验证用户、代次和桶关系。
public struct V2UserShardRouteCutoverHTTPRequest: Content, Sendable {
    /// 幂等切换标识。
    public let operationID: UUID
    /// 待切换用户的字符串标识。
    public let userID: String
    /// 预期全局路由代次。
    public let expectedRouterEpoch: Int64
    /// 目标逻辑写入桶。
    public let writeBucket: String
    /// 可选读取回退桶，切换控制层要求匹配迁移源桶。
    public let readFallbackBucket: String?

    /// 保存请求字段，不检查迁移状态、租约或存储中的当前路由。
    ///
    /// - Parameters:
    ///   - operationID: 幂等切换标识。
    ///   - userID: 待切换用户的字符串标识。
    ///   - expectedRouterEpoch: 预期全局路由代次。
    ///   - writeBucket: 目标逻辑写入桶。
    ///   - readFallbackBucket: 可选读取回退桶，切换控制层要求匹配迁移源桶。
    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64, writeBucket: String, readFallbackBucket: String?) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
        self.writeBucket = writeBucket
        self.readFallbackBucket = readFallbackBucket
    }

    /// 将用户字符串与路由参数转换为经过验证的领域命令。
    ///
    /// - Returns: 可交给路由控制服务的命令。
    /// - Throws: 用户标识或路由参数无效；处理器映射为 HTTP 400。
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

/// 切换与回滚共用的成功响应，幂等重放返回历史操作结果，不保证此时仍为最新路由。
public struct V2UserShardRouteCutoverHTTPResponse: Content, Equatable, Sendable {
    /// 本次请求的操作标识。
    public let operationID: UUID
    /// 服务返回的新写入桶或历史操作的写入桶。
    public let writeBucket: String
    /// 结果路由的代次，幂等重放时可能是历史值。
    public let routerEpoch: Int64
    /// 结果路由中的读取回退桶，不表示第二个写入目标。
    public let readFallbackBucket: String?
    /// 是否复用了既有操作结果。
    public let wasIdempotent: Bool
}

/// 单用户回滚请求，不接受调用方指定源桶或目标桶；归属由迁移记录确定。
public struct V2UserShardRouteRollbackHTTPRequest: Content, Sendable {
    /// 幂等回滚标识。
    public let operationID: UUID
    /// 待回滚用户的字符串标识。
    public let userID: String
    /// 预期当前路由代次。
    public let expectedRouterEpoch: Int64

    /// 保存请求字段，不检查迁移状态、租约或存储中的当前路由。
    ///
    /// - Parameters:
    ///   - operationID: 幂等回滚标识。
    ///   - userID: 待回滚用户的字符串标识。
    ///   - expectedRouterEpoch: 预期当前路由代次。
    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
    }

    /// 将用户字符串与路由参数转换为经过验证的领域命令。
    ///
    /// - Returns: 可交给路由控制服务的命令。
    /// - Throws: 用户标识或路由参数无效；处理器映射为 HTTP 400。
    func command() throws -> V2UserShardRouteRollback {
        try .init(operationID: operationID, userID: try UserID(userID), expectedRouterEpoch: expectedRouterEpoch)
    }
}

/// 用户分片路由操作员端点（切换与回滚）。
///
/// 处理器先验证操作员 Bearer 凭证，再解码并构造单用户领域命令，等待控制服务返回。
/// 本类型不配置监听地址或自行验证迁移指纹；部署入口隔离由外层负责，阶段及最终校验由控制层负责。
/// 使用默认 Content 解码，没有额外的未知字段拒绝逻辑。
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

    /// 注册单用户路由切换与回滚接口。
    ///
    /// - `POST /internal/v2/user-shard-routes/cutover`：切换到已验证迁移的目标桶。
    /// - `POST /internal/v2/user-shard-routes/rollback`：在控制层允许的窗口内恢复源桶。
    ///
    /// 两个入口鉴权失败返回 401；解码、命令构造及用户路由值错误返回 400；
    /// 操作冲突和陈旧代次返回 409。回滚另外将迁移冲突及迁移不满足条件映射为 409，
    /// 切换入口的这两类错误进入通用 503 映射。最终同步及未单独匹配的错误也返回 503。
    /// 成功返回 200 JSON，并设置 `Cache-Control: no-store` 与 `Pragma: no-cache`。
    /// 抛出的错误响应由外层中间件生成，本方法不统一附加禁止缓存头。
    ///
    /// - Parameter routes: 接收内部运维接口的路由集合。
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
