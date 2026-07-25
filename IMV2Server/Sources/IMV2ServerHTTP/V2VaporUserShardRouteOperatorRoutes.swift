import Foundation
import IMV2Core
import IMV2Server
import Vapor

public struct V2UserShardRouteCutoverHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let expectedRouterEpoch: Int64
    public let writeBucket: String
    public let readFallbackBucket: String?

    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64, writeBucket: String, readFallbackBucket: String?) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
        self.writeBucket = writeBucket
        self.readFallbackBucket = readFallbackBucket
    }

    func command() throws -> V2UserShardRouteCutover {
        try .init(
            operationID: operationID,
            userID: try UserID(userID),
            expectedRouterEpoch: expectedRouterEpoch,
            newWriteBucket: writeBucket,
            readFallbackBucket: readFallbackBucket
        )
    }
}

public struct V2UserShardRouteCutoverHTTPResponse: Content, Equatable, Sendable {
    public let operationID: UUID
    public let writeBucket: String
    public let routerEpoch: Int64
    public let readFallbackBucket: String?
    public let wasIdempotent: Bool
}

public struct V2UserShardRouteRollbackHTTPRequest: Content, Sendable {
    public let operationID: UUID
    public let userID: String
    public let expectedRouterEpoch: Int64

    public init(operationID: UUID, userID: String, expectedRouterEpoch: Int64) {
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
    }

    func command() throws -> V2UserShardRouteRollback {
        try .init(operationID: operationID, userID: try UserID(userID), expectedRouterEpoch: expectedRouterEpoch)
    }
}

/// A dedicated operator endpoint for a single, pre-verified cutover. It does
/// not copy data, accept raw SQL, expose physical locations, or permit batch
/// moves. The outer operator process remains loopback-only and bearer-gated.
public struct V2VaporUserShardRouteOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let control: any V2UserShardRouteCutoverHandling & V2UserShardRouteRollbackHandling

    public init(authenticator: V2OperatorReplayBearerAuthenticator, control: any V2UserShardRouteCutoverHandling & V2UserShardRouteRollbackHandling) {
        self.authenticator = authenticator
        self.control = control
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("internal", "v2", "user-shard-routes", "cutover") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2UserShardRouteCutover
            do { command = try request.content.decode(V2UserShardRouteCutoverHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2UserShardRouteCutoverResult
            do { result = try await control.cutOver(command) }
            catch V2UserShardRouteControlError.operationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.staleRouterEpoch { throw Abort(.conflict) }
            catch is V2UserShardRouterError { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            let body = try JSONEncoder().encode(V2UserShardRouteCutoverHTTPResponse(
                operationID: command.operationID,
                writeBucket: result.route.bucket,
                routerEpoch: result.route.observedRouterEpoch,
                readFallbackBucket: result.route.readFallbackBucket,
                wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: body))
        }
        routes.post("internal", "v2", "user-shard-routes", "rollback") { request async throws -> Response in
            guard authenticator.isAuthorized(bearerToken: request.headers.bearerAuthorization?.token) else {
                throw Abort(.unauthorized)
            }
            let command: V2UserShardRouteRollback
            do { command = try request.content.decode(V2UserShardRouteRollbackHTTPRequest.self).command() }
            catch { throw Abort(.badRequest) }
            let result: V2UserShardRouteCutoverResult
            do { result = try await control.rollBack(command) }
            catch V2UserShardRouteControlError.operationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.staleRouterEpoch { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.migrationConflict { throw Abort(.conflict) }
            catch V2UserShardRouteControlError.migrationNotVerified { throw Abort(.conflict) }
            catch is V2UserShardRouterError { throw Abort(.badRequest) }
            catch { throw Abort(.serviceUnavailable) }
            let body = try JSONEncoder().encode(V2UserShardRouteCutoverHTTPResponse(
                operationID: command.operationID, writeBucket: result.route.bucket,
                routerEpoch: result.route.observedRouterEpoch,
                readFallbackBucket: result.route.readFallbackBucket, wasIdempotent: result.wasIdempotent
            ))
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            return .init(status: .ok, headers: headers, body: .init(data: body))
        }
    }
}
