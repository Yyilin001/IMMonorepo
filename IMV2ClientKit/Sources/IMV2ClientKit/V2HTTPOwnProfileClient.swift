import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2OwnProfileManaging: Sendable {
    func currentProfile() async throws -> V2ProfileView
    func updateProfile(
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) async throws -> V2ProfileView
}

public enum V2OwnProfileClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case authorizationUnavailable
    case authorizationDenied
    case invalidRequest
    case revisionConflict(V2ProfileRevision)
    case invalidResponse
    case networkFailure
    case serverStatus(Int)
}

/// Authenticated no-store client for the complete own-profile document. The
/// caller owns retry identity and revision fencing; this adapter never retries
/// a write behind the user's back.
public struct V2HTTPOwnProfileClient: V2OwnProfileManaging, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2OwnProfileClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func currentProfile() async throws -> V2ProfileView {
        let request = try await authenticatedRequest(method: "GET")
        return try await send(request, expectedRevision: nil)
    }

    public func updateProfile(
        operationID: ProfileUpdateOperationID,
        expectedRevision: V2ProfileRevision,
        displayName: String,
        avatar: V2AvatarReference?
    ) async throws -> V2ProfileView {
        var request = try await authenticatedRequest(method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UpdateBody(
            operationID: operationID.rawValue,
            expectedRevision: expectedRevision.rawValue,
            displayName: displayName,
            avatarMediaID: avatar?.mediaID.rawValue
        ))
        return try await send(request, expectedRevision: expectedRevision)
    }

    private func authenticatedRequest(method: String) async throws -> URLRequest {
        let credential: V2ClientPushEndpointCredentials
        do { credential = try await credentials.pushEndpointCredentials() }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2OwnProfileClientError.authorizationUnavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func send(_ request: URLRequest, expectedRevision: V2ProfileRevision?) async throws -> V2ProfileView {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw V2OwnProfileClientError.networkFailure }
        if response.statusCode == 401 || response.statusCode == 403 { throw V2OwnProfileClientError.authorizationDenied }
        let body = try? JSONDecoder().decode(ResponseBody.self, from: data)
        if response.statusCode == 409 {
            guard let revision = body?.currentRevision.flatMap(V2ProfileRevision.init(rawValue:)) else {
                throw V2OwnProfileClientError.invalidResponse
            }
            throw V2OwnProfileClientError.revisionConflict(revision)
        }
        guard (200...299).contains(response.statusCode) else { throw V2OwnProfileClientError.serverStatus(response.statusCode) }
        guard let body, let view = try? body.profileView() else { throw V2OwnProfileClientError.invalidResponse }
        _ = expectedRevision
        return view
    }
}

private struct UpdateBody: Encodable {
    let operationID: String
    let expectedRevision: UInt64
    let displayName: String
    let avatarMediaID: String?
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", expectedRevision = "expected_revision"
        case displayName = "display_name", avatarMediaID = "avatar_media_id"
    }
}

private struct ResponseBody: Decodable {
    let userID: String?
    let handle: String?
    let displayName: String?
    let accountKind: V2AccountKind?
    let avatarMediaID: String?
    let state: V2ProfileState?
    let revision: UInt64?
    let visibilityRevision: UInt64?
    let currentRevision: UInt64?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", handle
        case displayName = "display_name", accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id", state, revision
        case visibilityRevision = "visibility_revision", currentRevision = "current_revision"
    }
    func profileView() throws -> V2ProfileView {
        guard let userID, let handle, let displayName, let accountKind, let state, let revision,
              let revision = V2ProfileRevision(rawValue: revision),
              let visibilityRevision, let visibilityRevision = V2ProfileRevision(rawValue: visibilityRevision)
        else { throw V2OwnProfileClientError.invalidResponse }
        let parsedUserID = try UserID(userID)
        let identity = try V2PublicIdentity(userID: parsedUserID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        return try .init(
            userID: parsedUserID,
            publicIdentity: identity,
            avatar: try avatarMediaID.map { try .init(mediaID: .init($0)) },
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        )
    }
}
