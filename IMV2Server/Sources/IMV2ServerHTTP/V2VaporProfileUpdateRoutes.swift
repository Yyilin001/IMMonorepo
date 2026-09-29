import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Vapor
import HTTPTypes

/// Field patches preserve unrelated changes; mutation receipts retain the original revision.
public struct V2VaporProfileUpdateRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let profiles: V2ProfileUpdateService
    public init(authenticator: any V2GatewayAuthenticator, profiles: V2ProfileUpdateService) {
        self.authenticator = authenticator; self.profiles = profiles
    }
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "profile", "me") { request async throws -> Response in
            let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            return try response(await profiles.currentProfile(for: actor.userID))
        }
        routes.on(.put, "v2", "profile", "me", maxBodySize: "8kb") { request async throws -> Response in
            let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            let input = try await request.content.decode(V2ProfileUpdateHTTPRequest.self)
            let command: V2ProfileUpdateCommand
            do {
                guard let revision = V2ProfileRevision(rawValue: input.expectedRevision) else { throw Abort(.badRequest) }
                command = try .init(actorUserID: actor.userID, operationID: .init(input.operationID), expectedRevision: revision,
                    patch: input.patch, firstSubmissionDeadlineMilliseconds: input.firstSubmissionDeadlineMilliseconds)
            } catch { throw Abort(.badRequest) }
            do { return try response(await profiles.update(command)) }
            catch V2ProfileUpdateError.operationPayloadMismatch { throw Abort(.conflict, reason: "fingerprint_conflict") }
            catch V2ProfileUpdateError.unavailable { throw Abort(.notFound) }
            catch { throw Abort(.serviceUnavailable) }
        }
        routes.on(.post, "v2", "profile", "me", "operations", "recover", maxBodySize: "2kb") { request async throws -> Response in
            let actor = try await request.v2AuthenticatedAccountIdentity(using: authenticator)
            let input = try await request.content.decode(V2ProfileOperationRecoveryHTTPRequest.self)
            let recovery: V2ProfileOperationRecoveryRequest
            do { recovery = try .init(actorUserID: actor.userID, operationID: .init(input.operationID), fingerprint: input.fingerprint, action: input.action) }
            catch { throw Abort(.badRequest) }
            do { return try response(await profiles.recover(recovery)) }
            catch { throw Abort(.serviceUnavailable) }
        }
    }
    private func response<T: Encodable>(_ value: T) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"; headers[.cacheControl] = "no-store"; headers[.v2Pragma] = "no-cache"
        return .init(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode(value)))
    }
}
public struct V2ProfileUpdateHTTPRequest: Content, Sendable {
    public let operationID: String
    public let expectedRevision: UInt64
    public let patch: V2ProfilePatch
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public init(operationID: String, expectedRevision: UInt64, patch: V2ProfilePatch, firstSubmissionDeadlineMilliseconds: UInt64) {
        self.operationID = operationID; self.expectedRevision = expectedRevision; self.patch = patch
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", expectedRevision = "expected_revision", patch
        case firstSubmissionDeadlineMilliseconds = "first_submission_deadline_ms"
    }
}
public struct V2ProfileOperationRecoveryHTTPRequest: Content, Sendable {
    public let operationID: String
    public let fingerprint: V2OperationFingerprint
    public let action: V2OperationRecoveryRequest.Action
    public init(operationID: String, fingerprint: V2OperationFingerprint, action: V2OperationRecoveryRequest.Action) {
        self.operationID = operationID; self.fingerprint = fingerprint; self.action = action
    }
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", fingerprint, action }
}
