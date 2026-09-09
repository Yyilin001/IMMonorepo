import Foundation
import IMV2Server
import Vapor

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

/// Registered only on the separate loopback operator process.
public struct V2VaporForwardWorkOperatorReplayRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2ForwardWorkOperatorReplayService
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2ForwardWorkOperatorReplayService) {
        self.authenticator = authenticator; self.service = service
    }
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
