import Foundation
import IMV2Core
import IMV2Server
import Vapor
import HTTPTypes

public struct V2DurableWorkReplayHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let targetKind: V2DurableWorkReplayTargetKind
    /// 个人事件来源库的已配置房间分片标识；其他工作必须为空。
    public let sourceShardID: String?
    public let sourceEventID: String
    public let targetUserID: String?
    public let projectionKind: String?
    public let reason: V2DurableWorkReplayReason

    public init(
        operationID: UUID,
        targetKind: V2DurableWorkReplayTargetKind,
        sourceShardID: String? = nil,
        sourceEventID: String,
        targetUserID: String? = nil,
        projectionKind: String? = nil,
        reason: V2DurableWorkReplayReason
    ) {
        self.operationID = operationID
        self.targetKind = targetKind
        self.sourceShardID = sourceShardID
        self.sourceEventID = sourceEventID
        self.targetUserID = targetUserID
        self.projectionKind = projectionKind
        self.reason = reason
    }

    func command() throws -> V2DurableWorkReplayCommand {
        let sourceEventID = try EventID(sourceEventID)
        let targetUserID = try targetUserID.map(UserID.init)
        let target = try V2DurableWorkReplayTarget(
            kind: targetKind,
            sourceEventID: sourceEventID,
            targetUserID: targetUserID,
            projectionKind: projectionKind
        )
        return .init(operationID: operationID, target: target, reason: reason)
    }
}

/// 按来源事件的批量重放请求。
///
/// 只携带精确的事件标识、封闭的类型与原因码，以及一个有界行数上限；目标集合由服务端
/// 在该事件内按稳定顺序选出，客户端无法表达扫描、筛选或自由文本。
public struct V2DurableWorkEventReplayHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let targetKind: V2DurableWorkReplayTargetKind
    /// 个人事件来源库的已配置房间分片标识；其他工作必须为空。
    public let sourceShardID: String?
    public let sourceEventID: String
    public let reason: V2DurableWorkReplayReason
    public let limit: Int

    public init(
        operationID: UUID,
        targetKind: V2DurableWorkReplayTargetKind,
        sourceShardID: String? = nil,
        sourceEventID: String,
        reason: V2DurableWorkReplayReason,
        limit: Int
    ) {
        self.operationID = operationID
        self.targetKind = targetKind
        self.sourceShardID = sourceShardID
        self.sourceEventID = sourceEventID
        self.reason = reason
        self.limit = limit
    }

    func command() throws -> V2DurableWorkEventReplayCommand {
        try .init(
            operationID: operationID,
            kind: targetKind,
            sourceEventID: try EventID(sourceEventID),
            reason: reason,
            limit: limit
        )
    }
}

/// 一次批量重放的响应。
public struct V2DurableWorkEventReplayHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let requeued: Int
    public let notPaused: Int
    public let hasMore: Bool

    init(_ result: V2DurableWorkEventReplayResult) {
        operationID = result.operationID
        requeued = result.requeued
        notPaused = result.notPaused
        hasMore = result.hasMore
    }
}

public struct V2DurableWorkReplayHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let outcome: V2DurableWorkReplayOutcome
    public let wasIdempotent: Bool

    init(_ result: V2DurableWorkReplayResult) {
        operationID = result.operationID
        outcome = result.outcome
        wasIdempotent = result.wasIdempotent
    }
}

/// `/internal/v2/durable-work/replay` 仅用于独立的 operator 回放进程。
///
/// 接口不接收端用户凭证、群角色参数或自由 SQL。单目标接口每次只回放一个精确目标；
/// 按来源事件的批量接口只回放**该事件**下的挂起行，且带行数上限，不提供扫描或自由筛选。
public struct V2VaporDurableWorkOperatorReplayRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2DurableWorkOperatorReplayService

    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2DurableWorkOperatorReplayService) {
        self.authenticator = authenticator
        self.service = service
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "durable-work", "replay-event") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let input = try await request.content.decode(V2DurableWorkEventReplayHTTPRequest.self)
            let command: V2DurableWorkEventReplayCommand
            do {
                command = try input.command()
            } catch {
                throw Abort(.badRequest)
            }
            let result: V2DurableWorkEventReplayResult
            do {
                result = try await service.replayEvent(command, sourceShardID: input.sourceShardID)
            } catch is V2DurableWorkReplayValidationError {
                throw Abort(.badRequest)
            } catch {
                // 数据库和意外的实现故障，不得通过运维接口泄露行身份或异常文本。
                throw Abort(.serviceUnavailable)
            }
            var response = Response(status: .ok, headers: [.cacheControl: "no-store", .v2Pragma: "no-cache"])
            try response.content.encode(V2DurableWorkEventReplayHTTPResponse(result))
            return response
        }
        routes.post("internal", "v2", "durable-work", "replay") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let input = try await request.content.decode(V2DurableWorkReplayHTTPRequest.self)
            let command: V2DurableWorkReplayCommand
            do {
                command = try input.command()
            } catch {
                throw Abort(.badRequest)
            }
            let result: V2DurableWorkReplayResult
            do {
                result = try await service.replay(command, sourceShardID: input.sourceShardID)
            } catch V2DurableWorkReplayStoreError.idempotencyConflict {
                throw Abort(.conflict)
            } catch is V2DurableWorkReplayValidationError {
                throw Abort(.badRequest)
            } catch {
                // 数据库和意外的实现故障，不得通过运维接口泄露行身份或异常文本。
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSON(.init(result))
        }
    }

    private func noStoreJSON(_ response: V2DurableWorkReplayHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
