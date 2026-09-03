import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Authenticated own-profile mutation requires both a revision fence and a
/// retry-safe operation ID, and treats avatar replacement as the same atomic
/// profile fact.
public struct V2VaporProfileUpdateRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let profiles: V2ProfileUpdateService

    public init(authenticator: any V2GatewayAuthenticator, profiles: V2ProfileUpdateService) {
        self.authenticator = authenticator
        self.profiles = profiles
    }

    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "profile", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            do {
                let view = try await profiles.currentProfile(for: actor.userID)
                return try noStoreJSONResponse(.init(view: view, idempotent: true))
            } catch is V2ProfileUpdateError {
                throw Abort(.serviceUnavailable)
            } catch {
                throw Abort(.serviceUnavailable)
            }
        }
        routes.put("v2", "profile", "me") { request async throws -> Response in
            let actor = try await authenticate(request)
            let input = try request.content.decode(V2ProfileUpdateHTTPRequest.self)
            let command: V2ProfileUpdateCommand
            do {
                guard let expectedRevision = V2ProfileRevision(rawValue: input.expectedRevision) else {
                    throw Abort(.badRequest)
                }
                command = try .init(
                    actorUserID: actor.userID,
                    operationID: .init(input.operationID),
                    expectedRevision: expectedRevision,
                    displayName: input.displayName,
                    avatar: try input.avatarMediaID.map { try .init(mediaID: .init($0)) }
                )
            } catch is Abort {
                throw Abort(.badRequest)
            } catch {
                throw Abort(.badRequest)
            }

            do {
                let outcome = try await profiles.update(command)
                let view: V2ProfileView
                let idempotent: Bool
                switch outcome {
                case .updated(let updated): view = updated; idempotent = false
                case .idempotent(let existing): view = existing; idempotent = true
                }
                return try noStoreJSONResponse(.init(view: view, idempotent: idempotent))
            } catch let error as V2ProfileUpdateError {
                switch error {
                case .revisionConflict(let current):
                    return try noStoreJSONResponse(
                        .init(currentRevision: current.rawValue), status: .conflict
                    )
                case .operationPayloadMismatch, .avatarUnavailable:
                    throw Abort(.badRequest)
                case .unavailable:
                    throw Abort(.notFound)
                case .corruptPersistenceState:
                    throw Abort(.serviceUnavailable)
                }
            }
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        try await request.v2AuthenticatedAccountIdentity(using: authenticator)
    }

    private func noStoreJSONResponse(_ result: V2ProfileUpdateHTTPResponse, status: HTTPResponseStatus = .ok) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: status, headers: headers, body: .init(data: data))
    }
}

public struct V2ProfileUpdateHTTPRequest: Content, Sendable {
    public let operationID: String
    public let expectedRevision: UInt64
    public let displayName: String
    /// `null` clears the avatar; the profile write is a complete desired state.
    public let avatarMediaID: String?

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case expectedRevision = "expected_revision"
        case displayName = "display_name"
        case avatarMediaID = "avatar_media_id"
    }
}

public struct V2ProfileUpdateHTTPResponse: Content, Sendable {
    public let userID: String?
    public let handle: String?
    public let displayName: String?
    public let accountKind: V2AccountKind?
    public let avatarMediaID: String?
    public let state: String?
    public let revision: UInt64?
    public let visibilityRevision: UInt64?
    public let idempotent: Bool?
    public let currentRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
        case idempotent
        case currentRevision = "current_revision"
    }

    init(view: V2ProfileView, idempotent: Bool) {
        userID = view.userID.rawValue
        handle = view.publicIdentity?.handle.rawValue
        displayName = view.publicIdentity?.displayName
        accountKind = view.publicIdentity?.accountKind
        avatarMediaID = view.avatar?.mediaID.rawValue
        state = view.state.rawValue
        revision = view.revision.rawValue
        visibilityRevision = view.visibilityRevision.rawValue
        self.idempotent = idempotent
        currentRevision = nil
    }

    init(currentRevision: UInt64) {
        userID = nil
        handle = nil
        displayName = nil
        accountKind = nil
        avatarMediaID = nil
        state = nil
        revision = nil
        visibilityRevision = nil
        idempotent = nil
        self.currentRevision = currentRevision
    }
}
