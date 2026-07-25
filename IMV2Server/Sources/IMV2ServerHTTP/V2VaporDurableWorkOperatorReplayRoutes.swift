import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2DurableWorkReplayHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let targetKind: V2DurableWorkReplayTargetKind
    public let sourceEventID: String
    public let targetUserID: String?
    public let projectionKind: String?
    public let reason: V2DurableWorkReplayReason

    public init(
        operationID: UUID,
        targetKind: V2DurableWorkReplayTargetKind,
        sourceEventID: String,
        targetUserID: String? = nil,
        projectionKind: String? = nil,
        reason: V2DurableWorkReplayReason
    ) {
        self.operationID = operationID
        self.targetKind = targetKind
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

/// `POST /internal/v2/durable-work/replay` belongs only on the separate,
/// loopback operator process. It deliberately accepts no end-user credential,
/// room role, free-form SQL, or batch target. One audited operation replays at
/// most one paused row.
public struct V2VaporDurableWorkOperatorReplayRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: V2DurableWorkOperatorReplayService

    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: V2DurableWorkOperatorReplayService) {
        self.authenticator = authenticator
        self.service = service
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "durable-work", "replay") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let input = try request.content.decode(V2DurableWorkReplayHTTPRequest.self)
            let command: V2DurableWorkReplayCommand
            do {
                command = try input.command()
            } catch {
                throw Abort(.badRequest)
            }
            let result: V2DurableWorkReplayResult
            do {
                result = try await service.replay(command)
            } catch V2DurableWorkReplayStoreError.idempotencyConflict {
                throw Abort(.conflict)
            } catch is V2DurableWorkReplayValidationError {
                throw Abort(.badRequest)
            } catch {
                // Database and unexpected implementation failures never
                // disclose row identity or exception text on the operator API.
                throw Abort(.serviceUnavailable)
            }
            return try noStoreJSON(.init(result))
        }
    }

    private func noStoreJSON(_ response: V2DurableWorkReplayHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(response)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}
