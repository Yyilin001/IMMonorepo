import Foundation
import IMV2Server
import Vapor

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

/// Only the independent loopback operator process registers these routes.
public struct V2VaporGroupApprovalRecoveryRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2GroupApprovalRecoveryService
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2GroupApprovalRecoveryService) {
        self.authenticator = authenticator; self.service = service
    }
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
private func approvalRecoveryHTTPError(_ error: any Error) -> Abort {
    switch error {
    case V2GroupApprovalRecoveryError.invalidRequest: return Abort(.badRequest)
    case V2GroupApprovalRecoveryError.unknownShard, V2GroupApprovalRecoveryError.requestNotFound: return Abort(.notFound)
    case V2GroupApprovalRecoveryError.ownerChanged, V2GroupApprovalRecoveryError.decisionChanged,
         V2GroupApprovalRecoveryError.idempotencyConflict: return Abort(.conflict)
    default: return Abort(.serviceUnavailable)
    }
}
