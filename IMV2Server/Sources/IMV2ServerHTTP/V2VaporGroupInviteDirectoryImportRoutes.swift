import Foundation
import IMV2Server
import Vapor

/// 群邀请目录导入请求体。
///
/// - Parameters:
///   - operationID: 幂等 ID。
///   - shardID: 分片 ID。
///   - ownerEpoch: 分片 owner epoch。
///   - roomID: 群组 ID。
///   - afterInviteID: 游标。
///   - limit: 分页大小。
///   - reason: 重放原因。
public struct V2GroupInviteDirectoryImportHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let shardID: String
    public let ownerEpoch: Int64
    public let roomID: UUID
    public let afterInviteID: UUID?
    public let limit: Int
    public let reason: V2DurableWorkReplayReason
    public init(operationID: UUID, shardID: String, ownerEpoch: Int64, roomID: UUID,
                afterInviteID: UUID?, limit: Int, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID; self.shardID = shardID; self.ownerEpoch = ownerEpoch
        self.roomID = roomID; self.afterInviteID = afterInviteID; self.limit = limit; self.reason = reason
    }
}

/// 邀请目录导入操作员路由。
///
/// 仅独立 operator 流程注册，支持单次有界分页导入。
public struct V2VaporGroupInviteDirectoryImportRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2GroupInviteDirectoryImporting
    /// 初始化。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2GroupInviteDirectoryImporting) {
        self.authenticator = authenticator; self.service = service
    }

    /// 挂载 `POST /internal/v2/group-invites/import-directory`。
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "group-invites", "import-directory") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else { throw Abort(.unauthorized) }
            let input = try request.content.decode(V2GroupInviteDirectoryImportHTTPRequest.self)
            do {
                let command = try V2GroupInviteDirectoryImportCommand(operationID: input.operationID,
                    shardID: input.shardID, ownerEpoch: input.ownerEpoch, roomID: input.roomID,
                    afterInviteID: input.afterInviteID, limit: input.limit, reason: input.reason)
                let result = try await service.importPage(command)
                var headers = HTTPHeaders()
                headers.replaceOrAdd(name: .contentType, value: "application/json")
                headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                headers.replaceOrAdd(name: "Pragma", value: "no-cache")
                return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(result)))
            } catch {
                switch error {
                case V2GroupInviteDirectoryImportError.invalidRequest: throw Abort(.badRequest)
                case V2GroupInviteDirectoryImportError.unknownShard: throw Abort(.notFound)
                case V2GroupInviteDirectoryImportError.ownerChanged, V2GroupInviteDirectoryImportError.idempotencyConflict: throw Abort(.conflict)
                default: throw Abort(.serviceUnavailable)
                }
            }
        }
    }
}
