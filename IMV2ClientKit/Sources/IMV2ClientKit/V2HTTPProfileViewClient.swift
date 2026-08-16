import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2ProfileViewReading: Sendable {
    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult]
}

public enum V2ProfileViewClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case authorizationUnavailable
    case authorizationDenied
    case invalidResponse
    case networkFailure
    case serverStatus(Int)
}

/// HTTPS account-edge adapter for bounded, viewer-authorized profile reads.
/// It deliberately uses a no-store request policy: durable profile state is
/// owned by the local SQLite projection, not by URLSession's shared cache.
public struct V2HTTPProfileViewClient: V2ProfileViewReading, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2ProfileViewClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        guard !keys.isEmpty, keys.count <= V2ProfileViewLookupLimits.maximumKeys, Set(keys).count == keys.count else {
            throw V2ProfileViewClientError.invalidRequest
        }
        let edgeCredentials: V2ClientPushEndpointCredentials
        do { edgeCredentials = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ProfileViewClientError.authorizationUnavailable }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(RequestBody(keys: keys.map(RequestKey.init)))

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2ProfileViewClientError.networkFailure }
        switch response.statusCode {
        case 200 ... 299: break
        case 400: throw V2ProfileViewClientError.invalidRequest
        case 401, 403: throw V2ProfileViewClientError.authorizationDenied
        default: throw V2ProfileViewClientError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw V2ProfileViewClientError.invalidResponse
        }
        let results: [V2ProfileViewLookupResult]
        do { results = try body.results.map { try $0.result() } }
        catch { throw V2ProfileViewClientError.invalidResponse }
        guard results.count == keys.count,
              Set(results.map(Self.key(for:))) == Set(keys)
        else { throw V2ProfileViewClientError.invalidResponse }
        return results
    }

    private static func key(for result: V2ProfileViewLookupResult) -> V2ProfileViewLookupKey {
        switch result {
        case .profile(let key, _), .unavailable(let key): key
        }
    }
}

private struct RequestBody: Encodable {
    let keys: [RequestKey]
}

private struct RequestKey: Encodable {
    let userID: String
    let context: String
    let roomID: String?

    init(_ key: V2ProfileViewLookupKey) {
        userID = key.userID.rawValue
        switch key.context {
        case .directConversation:
            context = "direct"
            roomID = nil
        case .relationship:
            context = "relationship"
            roomID = nil
        case .room(let roomID):
            context = "room"
            self.roomID = roomID.rawValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
    }
}

private struct ResponseBody: Decodable {
    let results: [ResponseItem]
}

private struct ResponseItem: Decodable {
    let userID: String
    let context: String
    let roomID: String?
    let unavailable: Bool
    let handle: String?
    let displayName: String?
    let accountKind: V2AccountKind?
    let avatarMediaID: String?
    let state: String?
    let revision: UInt64?
    let visibilityRevision: UInt64?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
        case unavailable
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    func result() throws -> V2ProfileViewLookupResult {
        let userID = try UserID(userID)
        let context: V2ProfileViewContext
        switch self.context {
        case "direct":
            guard roomID == nil else { throw V2ProfileViewClientError.invalidResponse }
            context = .directConversation
        case "relationship":
            guard roomID == nil else { throw V2ProfileViewClientError.invalidResponse }
            context = .relationship
        case "room":
            guard let roomID else { throw V2ProfileViewClientError.invalidResponse }
            context = .room(try RoomID(roomID))
        default:
            throw V2ProfileViewClientError.invalidResponse
        }
        let key = V2ProfileViewLookupKey(userID: userID, context: context)
        if unavailable {
            guard handle == nil, displayName == nil, accountKind == nil, avatarMediaID == nil,
                  state == nil, revision == nil, visibilityRevision == nil
            else { throw V2ProfileViewClientError.invalidResponse }
            return .unavailable(key: key)
        }
        guard let rawState = state,
              let state = V2ProfileState(rawValue: rawState),
              let revision, let profileRevision = V2ProfileRevision(rawValue: revision),
              let visibilityRevision, let accessRevision = V2ProfileRevision(rawValue: visibilityRevision)
        else { throw V2ProfileViewClientError.invalidResponse }
        let identity: V2PublicIdentity?
        switch (handle, displayName, accountKind) {
        case (.none, .none, .none): identity = nil
        case let (.some(handle), .some(displayName), .some(accountKind)):
            identity = try .init(userID: userID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        default: throw V2ProfileViewClientError.invalidResponse
        }
        let avatar = try avatarMediaID.map { try V2AvatarReference(mediaID: .init($0)) }
        let view = try V2ProfileView(
            userID: userID,
            publicIdentity: identity,
            avatar: avatar,
            state: state,
            revision: profileRevision,
            visibilityRevision: accessRevision
        )
        return .profile(key: key, view: view)
    }
}
