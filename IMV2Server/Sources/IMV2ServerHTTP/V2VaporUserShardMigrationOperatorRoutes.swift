import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 单用户迁移初次复制校验的 HTTP 请求体。
///
/// 仅描述逻辑桶与路由代次，不接受物理连接配置。初始化只保存字段，路由解码后
/// 再转换为领域准备请求，完成用户标识和迁移参数校验。
public struct V2UserShardMigrationCopyVerifyHTTPRequest: Content, Sendable {
    /// 迁移操作标识，用于匹配已有准备请求。
    public let migrationID: UUID
    /// 待迁移用户的字符串标识，转换时须满足 `UserID` 约束。
    public let userID: String
    /// 源逻辑桶，领域转换时规范化首尾空白。
    public let sourceBucket: String
    /// 目标逻辑桶，领域转换时按用户路由规则验证。
    public let targetBucket: String
    /// 准备请求所依据的源路由代次，不在 HTTP 层自行与存储比较。
    public let sourceRouterEpoch: Int64

    /// 构造请求数据，不执行领域校验或网络调用。
    ///
    /// - Parameters:
    ///   - migrationID: 迁移操作标识，用于匹配已有准备请求。
    ///   - userID: 待迁移用户的字符串标识，转换时须满足 `UserID` 约束。
    ///   - sourceBucket: 源逻辑桶，领域转换时规范化首尾空白。
    ///   - targetBucket: 目标逻辑桶，领域转换时按用户路由规则验证。
    ///   - sourceRouterEpoch: 准备请求所依据的源路由代次，不在 HTTP 层自行与存储比较。
    public init(migrationID: UUID, userID: String, sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64) {
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = sourceBucket
        self.targetBucket = targetBucket
        self.sourceRouterEpoch = sourceRouterEpoch
    }

    /// 将传输字段转换为经过验证的迁移准备请求。
    ///
    /// - Returns: 规范化源桶、目标桶及代次后的领域请求。
    /// - Throws: 用户标识、目标路由或迁移准备参数校验错误；路由层映射为 HTTP 400。
    func preparation() throws -> V2UserShardMigrationPreparation {
        try .init(
            migrationID: migrationID, userID: try UserID(userID), sourceBucket: sourceBucket,
            targetBucket: targetBucket, sourceRouterEpoch: sourceRouterEpoch
        )
    }
}

/// 初次复制校验与转发复核共用的成功响应体。
///
/// 正常初次校验返回 forwarding，转发复核返回 verified；实际 phase 原样来自服务结果。
/// 响应不包含指纹、物理端点或原始适配器错误，成功也不代表路由已经切换。
public struct V2UserShardMigrationCopyVerifyHTTPResponse: Content, Equatable, Sendable {
    /// 服务返回的迁移标识。
    public let migrationID: UUID
    /// 本次服务调用返回的迁移阶段。
    public let phase: V2UserShardMigrationPhase
    /// 是否直接复用了当前阶段的结果；并不表示迁移全流程已经完成。
    public let wasIdempotent: Bool
}

/// 对已存在迁移发起转发阶段指纹复核的请求体，不重新指定源桶或目标桶。
public struct V2UserShardMigrationForwardingVerifyHTTPRequest: Content, Sendable {
    /// 要复核的持久化迁移标识。
    public let migrationID: UUID
    /// 保存复核目标，不检查记录是否存在或阶段是否允许。
    ///
    /// - Parameter migrationID: 目标迁移标识。
    public init(migrationID: UUID) { self.migrationID = migrationID }
}

/// 分片迁移操作员路由。
///
/// 每个处理器先验证操作员 Bearer 凭证，再解析请求并等待服务调用完成。
/// 只接受单用户迁移或单迁移 ID 的复制校验、转发复核，不执行路由切换。
/// 请求体使用类型的默认 Content 解码，没有额外的未知字段拒绝逻辑。
/// 本类型不启动后台作业；成功结果以禁止缓存的 JSON 响应返回。
public struct V2VaporUserShardMigrationOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2UserShardMigrationCopyVerifyHandling & V2UserShardMigrationForwardingVerifyHandling

    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员鉴权器。
    ///   - service: 复制校验与转发校验服务。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2UserShardMigrationCopyVerifyHandling & V2UserShardMigrationForwardingVerifyHandling) {
        self.authenticator = authenticator
        self.service = service
    }

    /// 注册初次复制校验与转发复核两个 POST 接口。
    ///
    /// - `POST /internal/v2/user-shard-migrations/copy-verify`：准备后执行初次复制校验。
    /// - `POST /internal/v2/user-shard-migrations/verify-forwarding`：复核已有迁移的转发结果。
    ///
    /// 鉴权失败返回 401，解码或准备参数失败返回 400，阶段及请求冲突返回 409。
    /// 复核入口的记录缺失返回 404；指纹不一致及其他执行错误返回 503。
    /// 存储注册表错误在初次校验入口映射为 400，在复核入口落入通用 503 映射。
    /// 成功返回 200 JSON，并设置 `Cache-Control: no-store` 和 `Pragma: no-cache`；
    /// 抛出的错误响应由 Vapor 中间件生成，不在本方法中统一附加这些缓存头。
    ///
    /// - Parameter routes: 接收内部运维接口的路由集合，部署方负责选择对应监听入口。
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "user-shard-migrations", "copy-verify") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let preparation: V2UserShardMigrationPreparation
            do { preparation = try request.content.decode(V2UserShardMigrationCopyVerifyHTTPRequest.self).preparation() }
            catch { throw Abort(.badRequest) }
            let result: (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
            do { result = try await service.prepareCopyAndVerify(preparation) }
            catch V2UserShardMigrationOperatorError.inProgress { throw Abort(.conflict) }
            catch V2UserShardMigrationStoreError.requestConflict { throw Abort(.conflict) }
            catch V2UserShardMigrationStoreError.phaseConflict { throw Abort(.conflict) }
            catch is V2UserShardMigrationError { throw Abort(.conflict) }
            catch is V2UserShardMigrationVerificationError { throw Abort(.serviceUnavailable) }
            catch is V2UserShardStorageRegistryError { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            let body = try JSONEncoder().encode(V2UserShardMigrationCopyVerifyHTTPResponse(
                migrationID: result.record.migrationID, phase: result.record.phase, wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: body))
        }
        routes.post("internal", "v2", "user-shard-migrations", "verify-forwarding") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let body: V2UserShardMigrationForwardingVerifyHTTPRequest
            do { body = try request.content.decode(V2UserShardMigrationForwardingVerifyHTTPRequest.self) }
            catch { throw Abort(.badRequest) }
            let result: (record: V2UserShardMigrationRecord, wasIdempotent: Bool)
            do { result = try await service.verifyForwarding(migrationID: body.migrationID) }
            catch V2UserShardMigrationOperatorError.inProgress { throw Abort(.conflict) }
            catch V2UserShardMigrationStoreError.phaseConflict { throw Abort(.conflict) }
            catch V2UserShardMigrationStoreError.recordNotFound { throw Abort(.notFound) }
            catch is V2UserShardMigrationError { throw Abort(.conflict) }
            catch is V2UserShardMigrationVerificationError { throw Abort(.serviceUnavailable) }
            catch { throw Abort(.serviceUnavailable) }
            let encoded = try JSONEncoder().encode(V2UserShardMigrationCopyVerifyHTTPResponse(
                migrationID: result.record.migrationID, phase: result.record.phase, wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: encoded))
        }
    }
}
