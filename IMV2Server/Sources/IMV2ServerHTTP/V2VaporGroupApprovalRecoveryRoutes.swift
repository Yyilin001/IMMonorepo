import Foundation
import IMV2Server
import Vapor

/// 群审批恢复请求体。
///
/// - Parameters:
///   - operationID: 幂等操作标识。
///   - shardID: 分片标识。
///   - ownerEpoch: 分片拥有者 epoch。
///   - roomID: 群组 ID。
///   - requestID: 申请 ID。
///   - reviewerUserID: 审批者用户 ID。
///   - decisionOperationID: 决策幂等 ID。
///   - reason: 恢复原因。
public struct V2GroupApprovalRecoveryHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let shardID: String
    public let ownerEpoch: Int64
    public let roomID: UUID
    public let requestID: UUID
    public let reviewerUserID: UUID
    public let decisionOperationID: UUID
    public let reason: V2DurableWorkReplayReason
    public init(operationID: UUID, shardID: String, ownerEpoch: Int64, roomID: UUID,
                requestID: UUID, reviewerUserID: UUID, decisionOperationID: UUID, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID; self.shardID = shardID; self.ownerEpoch = ownerEpoch; self.roomID = roomID
        self.requestID = requestID; self.reviewerUserID = reviewerUserID; self.decisionOperationID = decisionOperationID; self.reason = reason
    }
}
/// 群审批候选查询请求体。
///
/// - Parameters:
///   - shardID: 分片标识。
///   - ownerEpoch: 分片拥有者 epoch。
///   - roomID: 群组 ID。
///   - after: 分页游标。
///   - limit: 单页上限。
public struct V2GroupApprovalRecoveryCandidatesHTTPRequest: Content, Sendable {
    public let shardID: String
    public let ownerEpoch: Int64
    public let roomID: UUID
    public let after: UUID?
    public let limit: Int
    public init(shardID: String, ownerEpoch: Int64, roomID: UUID, after: UUID?, limit: Int) {
        self.shardID = shardID; self.ownerEpoch = ownerEpoch; self.roomID = roomID; self.after = after; self.limit = limit
    }
}

/// 仅由独立的 operator 回放服务注册的群审批恢复路由。
///
/// - `POST /internal/v2/group-approvals/candidates`：查询待恢复候选。
/// - `POST /internal/v2/group-approvals/recover`：重放恢复一条审批。
public struct V2VaporGroupApprovalRecoveryRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2GroupApprovalRecoveryService
    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员鉴权器。
    ///   - service: 群审批恢复服务。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2GroupApprovalRecoveryService) {
        self.authenticator = authenticator; self.service = service
    }
    /// 挂载恢复相关端点。
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "group-approvals", "candidates") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else { throw Abort(.unauthorized) }
            let input = try request.content.decode(V2GroupApprovalRecoveryCandidatesHTTPRequest.self)
            do {
                let scope = try V2GroupApprovalRecoveryScope(shardID: input.shardID, ownerEpoch: input.ownerEpoch, roomID: input.roomID)
                return try approvalRecoveryResponse(try await service.candidates(scope: scope, after: input.after, limit: input.limit))
            } catch { throw approvalRecoveryHTTPError(error) }
        }
        routes.post("internal", "v2", "group-approvals", "recover") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else { throw Abort(.unauthorized) }
            let input = try request.content.decode(V2GroupApprovalRecoveryHTTPRequest.self)
            do {
                let scope = try V2GroupApprovalRecoveryScope(shardID: input.shardID, ownerEpoch: input.ownerEpoch, roomID: input.roomID)
                let command = V2GroupApprovalRecoveryCommand(operationID: input.operationID, scope: scope,
                    requestID: input.requestID, reviewerUserID: input.reviewerUserID,
                    decisionOperationID: input.decisionOperationID, reason: input.reason)
                return try approvalRecoveryResponse(try await service.recover(command))
            } catch { throw approvalRecoveryHTTPError(error) }
        }
    }
}
private func approvalRecoveryResponse<T: Encodable>(_ value: T) throws -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .contentType, value: "application/json")
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    headers.replaceOrAdd(name: "Pragma", value: "no-cache")
    return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
}

/// 群审批恢复错误到 HTTP 状态码的统一映射。
private func approvalRecoveryHTTPError(_ error: any Error) -> Abort {
    switch error {
    case V2GroupApprovalRecoveryError.invalidRequest: return Abort(.badRequest)
    case V2GroupApprovalRecoveryError.unknownShard, V2GroupApprovalRecoveryError.requestNotFound: return Abort(.notFound)
    case V2GroupApprovalRecoveryError.ownerChanged, V2GroupApprovalRecoveryError.decisionChanged,
         V2GroupApprovalRecoveryError.idempotencyConflict: return Abort(.conflict)
    default: return Abort(.serviceUnavailable)
    }
}
