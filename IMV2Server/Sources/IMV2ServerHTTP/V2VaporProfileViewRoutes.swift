import Foundation
import IMV2Core
import IMV2Server
import Vapor

/// Authenticated, context-authorized profile hydration. Unlike the exact
/// handle directory, this API accepts only stable IDs already learned from a
/// direct room or an authorized group context, and returns an indistinguishable
/// unavailable result for every non-readable key.
public struct V2VaporProfileViewRoutes: Sendable {
    private let authenticator: any V2GatewayAuthenticator
    private let profiles: V2ProfileViewService

    public init(authenticator: any V2GatewayAuthenticator, profiles: V2ProfileViewService) {
        self.authenticator = authenticator
        self.profiles = profiles
    }

    public func register(on routes: RoutesBuilder) {
        routes.post("v2", "profile-views", "batch") { request async throws -> Response in
            let actor = try await authenticate(request)
            let input = try request.content.decode(V2ProfileViewBatchHTTPRequest.self)
            let keys: [V2ProfileViewLookupKey]
            do {
                keys = try input.keys.map { try $0.lookupKey() }
                let read = try V2ProfileViewReadRequest(actorUserID: actor.userID, keys: keys)
                let results = try await profiles.read(read)
                return try noStoreJSONResponse(.init(results: results.map(V2ProfileViewBatchHTTPResult.init)))
            } catch V2ProfileViewReadError.invalidRequest {
                throw Abort(.badRequest)
            } catch V2ProfileViewReadError.corruptPersistenceState {
                throw Abort(.serviceUnavailable)
            }
        }
    }

    private func authenticate(_ request: Request) async throws -> V2AuthenticatedConnection {
        guard let accessToken = request.headers.bearerAuthorization?.token,
              let rawDeviceID = request.headers.first(name: "X-IM-Device-ID"),
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw Abort(.unauthorized) }
        do {
            let userID = try await authenticator.authenticate(accessToken: accessToken, deviceID: deviceID)
            return .init(userID: userID, deviceID: deviceID, capabilityProfile: "account-edge")
        } catch {
            throw Abort(.unauthorized)
        }
    }

    private func noStoreJSONResponse(_ result: V2ProfileViewBatchHTTPResponse) throws -> Response {
        let data = try JSONEncoder().encode(result)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "Pragma", value: "no-cache")
        return .init(status: .ok, headers: headers, body: .init(data: data))
    }
}

public struct V2ProfileViewBatchHTTPRequest: Content, Sendable {
    public let keys: [V2ProfileViewLookupHTTPKey]
    public init(keys: [V2ProfileViewLookupHTTPKey]) { self.keys = keys }
}

public struct V2ProfileViewLookupHTTPKey: Content, Sendable {
    public let userID: String
    /// `context` is explicit so an absent room ID cannot accidentally turn a
    /// relationship contact read into a direct-room authorization check.
    public let context: String
    public let roomID: String?

    public init(userID: String, context: String = "direct", roomID: String? = nil) {
        self.userID = userID
        self.context = context
        self.roomID = roomID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
    }

    fileprivate func lookupKey() throws -> V2ProfileViewLookupKey {
        let userID = try UserID(userID)
        switch context {
        case "direct":
            guard roomID == nil else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .directConversation)
        case "relationship":
            guard roomID == nil else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .relationship)
        case "room":
            guard let roomID else { throw V2ProfileViewReadError.invalidRequest }
            return .init(userID: userID, context: .room(try RoomID(roomID)))
        default:
            throw V2ProfileViewReadError.invalidRequest
        }
    }
}

public struct V2ProfileViewBatchHTTPResponse: Content, Sendable {
    public let results: [V2ProfileViewBatchHTTPResult]
    public init(results: [V2ProfileViewBatchHTTPResult]) { self.results = results }
}

public struct V2ProfileViewBatchHTTPResult: Content, Sendable {
    public let userID: String
    public let context: String
    public let roomID: String?
    public let unavailable: Bool
    public let handle: String?
    public let displayName: String?
    public let avatarMediaID: String?
    public let state: String?
    public let revision: UInt64?
    public let visibilityRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
        case unavailable
        case handle
        case displayName = "display_name"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    init(_ result: V2ProfileViewLookupResult) {
        switch result {
        case .unavailable(let key):
            userID = key.userID.rawValue
            context = Self.context(for: key.context)
            roomID = Self.roomID(for: key.context)
            unavailable = true
            handle = nil
            displayName = nil
            avatarMediaID = nil
            state = nil
            revision = nil
            visibilityRevision = nil
        case .profile(let key, let view):
            userID = key.userID.rawValue
            context = Self.context(for: key.context)
            roomID = Self.roomID(for: key.context)
            unavailable = false
            handle = view.publicIdentity?.handle.rawValue
            displayName = view.publicIdentity?.displayName
            avatarMediaID = view.avatar?.mediaID.rawValue
            state = view.state.rawValue
            revision = view.revision.rawValue
            visibilityRevision = view.visibilityRevision.rawValue
        }
    }

    private static func roomID(for context: V2ProfileViewContext) -> String? {
        switch context {
        case .directConversation: nil
        case .relationship: nil
        case .room(let roomID): roomID.rawValue
        }
    }

    private static func context(for context: V2ProfileViewContext) -> String {
        switch context {
        case .directConversation: "direct"
        case .relationship: "relationship"
        case .room: "room"
        }
    }
}
