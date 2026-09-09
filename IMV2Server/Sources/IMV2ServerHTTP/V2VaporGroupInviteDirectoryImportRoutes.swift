import Foundation
import IMV2Server
import Vapor

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

/// Only the independent operator process registers this bounded, audited import.
public struct V2VaporGroupInviteDirectoryImportRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2GroupInviteDirectoryImporting
    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2GroupInviteDirectoryImporting) {
        self.authenticator = authenticator; self.service = service
    }
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
