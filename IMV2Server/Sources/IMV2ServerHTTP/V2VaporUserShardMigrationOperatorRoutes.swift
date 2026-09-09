import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// 用户分片迁移复制校验请求体。
///
/// - Parameters:
///   - migrationID: 迁移操作 ID。
///   - userID: 用户 ID。
///   - sourceBucket: 源分片。
///   - targetBucket: 目标分片。
///   - sourceRouterEpoch: 源路由器 epoch。
public struct V2UserShardMigrationCopyVerifyHTTPRequest: Content, Sendable {
    public let migrationID: UUID
    public let userID: String
    public let sourceBucket: String
    public let targetBucket: String
    public let sourceRouterEpoch: Int64

    public init(migrationID: UUID, userID: String, sourceBucket: String, targetBucket: String, sourceRouterEpoch: Int64) {
        self.migrationID = migrationID
        self.userID = userID
        self.sourceBucket = sourceBucket
        self.targetBucket = targetBucket
        self.sourceRouterEpoch = sourceRouterEpoch
    }

    func preparation() throws -> V2UserShardMigrationPreparation {
        try .init(
            migrationID: migrationID, userID: try UserID(userID), sourceBucket: sourceBucket,
            targetBucket: targetBucket, sourceRouterEpoch: sourceRouterEpoch
        )
    }
}

/// 复制校验结果响应体。
public struct V2UserShardMigrationCopyVerifyHTTPResponse: Content, Equatable, Sendable {
    public let migrationID: UUID
    public let phase: V2UserShardMigrationPhase
    public let wasIdempotent: Bool
}

/// 转发链路校验请求体。
public struct V2UserShardMigrationForwardingVerifyHTTPRequest: Content, Sendable {
    public let migrationID: UUID
    public init(migrationID: UUID) { self.migrationID = migrationID }
}

/// 分片迁移操作员路由。
///
/// 该接口只允许对单个用户执行复制校验与转发校验，不接受连接串、SQL 或
/// 批量迁移参数，避免变成通用分片管理 API。
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

    /// 挂载：
    /// - `POST /internal/v2/user-shard-migrations/copy-verify`
    /// - `POST /internal/v2/user-shard-migrations/verify-forwarding`
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
