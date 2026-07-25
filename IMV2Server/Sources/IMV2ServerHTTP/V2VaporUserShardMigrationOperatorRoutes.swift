import Foundation
import IMV2Core
import IMV2Server
import Vapor

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

public struct V2UserShardMigrationCopyVerifyHTTPResponse: Content, Equatable, Sendable {
    public let migrationID: UUID
    public let phase: V2UserShardMigrationPhase
    public let wasIdempotent: Bool
}

public struct V2UserShardMigrationForwardingVerifyHTTPRequest: Content, Sendable {
    public let migrationID: UUID
    public init(migrationID: UUID) { self.migrationID = migrationID }
}

/// The operator may prepare and physically copy/verify precisely one user.
/// It never accepts a connection string, raw SQL, a migration range or a
/// cutover request; those boundaries prevent it becoming a shard admin API.
public struct V2VaporUserShardMigrationOperatorRoutes: Sendable {
    private let authenticator: V2OperatorReplayBearerAuthenticator
    private let service: any V2UserShardMigrationCopyVerifyHandling & V2UserShardMigrationForwardingVerifyHandling

    public init(authenticator: V2OperatorReplayBearerAuthenticator, service: any V2UserShardMigrationCopyVerifyHandling & V2UserShardMigrationForwardingVerifyHandling) {
        self.authenticator = authenticator
        self.service = service
    }

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
