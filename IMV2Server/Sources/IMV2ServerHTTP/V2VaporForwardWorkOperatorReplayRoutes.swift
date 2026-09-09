import Foundation
import IMV2Server
import Vapor

/// 转发工作重放请求体。
///
/// - Parameters:
///   - operationID: 幂等 ID。
///   - shardID: 分片 ID。
///   - kind: 重放类型。
///   - exportID: 导出 ID。
///   - ordinal: 分批序号（可选）。
///   - reason: 重放原因。
public struct V2ForwardWorkReplayHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let shardID: String
    public let kind: V2ForwardWorkReplayKind
    public let exportID: UUID
    public let ordinal: Int?
    public let reason: V2DurableWorkReplayReason
    public init(operationID: UUID, shardID: String, kind: V2ForwardWorkReplayKind, exportID: UUID,
                ordinal: Int? = nil, reason: V2DurableWorkReplayReason) {
        self.operationID = operationID; self.shardID = shardID; self.kind = kind
        self.exportID = exportID; self.ordinal = ordinal; self.reason = reason
    }
}

/// 仅在独立 loopback operator 进程注册的重放路由。
public struct V2VaporForwardWorkOperatorReplayRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2ForwardWorkOperatorReplayService
    /// 初始化。
    ///
    /// - Parameters:
    ///   - authenticator: 操作员鉴权器。
    ///   - service: 重放服务。
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2ForwardWorkOperatorReplayService) {
        self.authenticator = authenticator; self.service = service
    }

    /// 挂载 `POST /internal/v2/forward-work/replay`。
    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "forward-work", "replay") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else { throw Abort(.unauthorized) }
            let input = try request.content.decode(V2ForwardWorkReplayHTTPRequest.self)
            let command: V2ForwardWorkReplayCommand
            do {
                command = try .init(operationID: input.operationID, shardID: input.shardID, kind: input.kind,
                    exportID: input.exportID, ordinal: input.ordinal, reason: input.reason)
            } catch { throw Abort(.badRequest) }
            let result: V2DurableWorkReplayResult
            do { result = try await service.replay(command)
            } catch V2ForwardWorkReplayError.invalidTarget { throw Abort(.badRequest)
            } catch V2ForwardWorkReplayError.unknownShard { throw Abort(.notFound)
            } catch V2ForwardWorkReplayError.targetUnavailable { throw Abort(.notFound)
            } catch V2ForwardWorkReplayError.ownerChanged { throw Abort(.conflict)
            } catch V2ForwardWorkReplayError.idempotencyConflict { throw Abort(.conflict)
            } catch { throw Abort(.serviceUnavailable) }
            let data = try JSONEncoder().encode(V2DurableWorkReplayHTTPResponse(result))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: data))
        }
    }
}
