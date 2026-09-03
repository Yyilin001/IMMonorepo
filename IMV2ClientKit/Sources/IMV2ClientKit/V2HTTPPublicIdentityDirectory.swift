import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Resolves one exact public handle at the authenticated account edge. It has
/// no cache or batch API: durable profile projections belong to the sync layer,
/// while this boundary is solely for an explicit user action such as starting
/// a direct chat or adding a group member.
public protocol V2PublicIdentityResolving: Sendable {
    func resolve(handle: String) async throws -> V2PublicIdentity
}

public enum V2PublicIdentityDirectoryClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidHandle
    case authorizationUnavailable
    case authorizationDenied
    case notFound
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse
    case networkFailure
    case serverStatus(Int)
}

public struct V2HTTPPublicIdentityDirectory: V2PublicIdentityResolving, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { throw V2PublicIdentityDirectoryClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func resolve(handle: String) async throws -> V2PublicIdentity {
        let canonical: V2PublicHandle
        do { canonical = try .init(handle) } catch { throw V2PublicIdentityDirectoryClientError.invalidHandle }
        let edgeCredentials: V2ClientPushEndpointCredentials
        do { edgeCredentials = try await credentials.pushEndpointCredentials() } catch is CancellationError { throw CancellationError() }
        catch { throw V2PublicIdentityDirectoryClientError.authorizationUnavailable }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "handle", value: canonical.rawValue)]
        guard let url = components?.url else { throw V2PublicIdentityDirectoryClientError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) } catch is CancellationError { throw CancellationError() }
        catch { throw V2PublicIdentityDirectoryClientError.networkFailure }
        switch response.statusCode {
        case 200 where V2HTTPContract.isJSON(response): break
        case 200: throw V2PublicIdentityDirectoryClientError.invalidResponse
        case 401, 403: throw V2PublicIdentityDirectoryClientError.authorizationDenied
        case 404: throw V2PublicIdentityDirectoryClientError.notFound
        case 429: throw V2PublicIdentityDirectoryClientError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw V2PublicIdentityDirectoryClientError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(IdentityResponse.self, from: data),
              let userID = try? UserID(body.userID),
              let identity = try? V2PublicIdentity(userID: userID, handle: .init(body.handle), displayName: body.displayName, accountKind: body.accountKind)
        else { throw V2PublicIdentityDirectoryClientError.invalidResponse }
        return identity
    }
}

private struct IdentityResponse: Decodable {
    let userID: String
    let handle: String
    let displayName: String
    let accountKind: V2AccountKind

}
