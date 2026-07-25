import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// Narrow provider set mirrored by the account edge. It is intentionally not
/// an open string so an app update cannot opt into an unreviewed provider.
public enum V2ClientPushEndpointProvider: String, Codable, Equatable, Sendable {
    case apns
}

/// APNs environment is a deployment choice, not a user-controlled label.
public enum V2ClientPushEndpointEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

/// A coherent access-token/device pair used only at the authenticated account
/// edge. The bearer token and opaque Push token must never be persisted,
/// logged, attached to analytics, or included in a returned value.
public struct V2ClientPushEndpointCredentials: Sendable {
    public let accessToken: String
    public let deviceID: DeviceID

    public init(accessToken: String, deviceID: DeviceID) {
        self.accessToken = accessToken
        self.deviceID = deviceID
    }
}

public protocol V2ClientPushEndpointCredentialProvider: Sendable {
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials
}

/// Isolates URLSession so endpoint registration tests remain offline and do
/// not need a process-global URLProtocol registration.
public protocol V2ClientPushEndpointHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public actor V2URLSessionPushEndpointHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw V2ClientPushEndpointError.invalidResponse
        }
        return (data, response)
    }
}

/// Framework-neutral account-edge contract for a device-owned endpoint.
/// Registration and removal are deliberately non-retrying writes: callers
/// must first obtain a current OS-provided token and explicitly decide when to
/// repeat after failure.
public protocol V2ClientPushEndpointRegistering: Sendable {
    func register(
        provider: V2ClientPushEndpointProvider,
        environment: V2ClientPushEndpointEnvironment,
        token: String
    ) async throws
    func remove() async throws
}

/// HTTPS implementation of the authenticated `PUT|DELETE /v2/push-endpoint`
/// contract. It does not expose a read API because an endpoint token is not
/// application state and must not re-enter client persistence.
public struct V2HTTPPushEndpointClient: V2ClientPushEndpointRegistering, Sendable {
    private let endpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport

    public init(
        endpoint: URL,
        credentials: any V2ClientPushEndpointCredentialProvider,
        transport: any V2ClientPushEndpointHTTPTransport = V2URLSessionPushEndpointHTTPTransport()
    ) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            throw V2ClientPushEndpointError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
    }

    public func register(
        provider: V2ClientPushEndpointProvider,
        environment: V2ClientPushEndpointEnvironment,
        token: String
    ) async throws {
        guard Self.isValidOpaqueToken(token) else {
            throw V2ClientPushEndpointError.invalidRegistration
        }
        var request = try await authenticatedRequest(method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                V2PushEndpointRegistrationBody(provider: provider, environment: environment, token: token)
            )
        } catch {
            throw V2ClientPushEndpointError.invalidRegistration
        }
        try await sendNoContent(request)
    }

    public func remove() async throws {
        try await sendNoContent(try await authenticatedRequest(method: "DELETE"))
    }

    private func authenticatedRequest(method: String) async throws -> URLRequest {
        try Task.checkCancellation()
        let edgeCredentials: V2ClientPushEndpointCredentials
        do {
            edgeCredentials = try await credentials.pushEndpointCredentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2ClientPushEndpointError.authorizationUnavailable
        }
        guard !edgeCredentials.accessToken.isEmpty,
              !edgeCredentials.accessToken.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2ClientPushEndpointError.authorizationUnavailable }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = method
        request.setValue("Bearer \(edgeCredentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(edgeCredentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private func sendNoContent(_ request: URLRequest) async throws {
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2ClientPushEndpointError {
            throw error
        } catch {
            throw V2ClientPushEndpointError.networkFailure
        }
        switch response.statusCode {
        case 200 ... 299: return
        case 400: throw V2ClientPushEndpointError.invalidRegistration
        case 401, 403: throw V2ClientPushEndpointError.authorizationDenied
        default: throw V2ClientPushEndpointError.serverStatus(response.statusCode)
        }
    }

    private static func isValidOpaqueToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized == token && normalized.utf8.count <= 4_096
            && normalized.unicodeScalars.allSatisfy {
                !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum V2ClientPushEndpointError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRegistration
    case authorizationUnavailable
    case authorizationDenied
    case invalidResponse
    case serverStatus(Int)
    case networkFailure
}

private struct V2PushEndpointRegistrationBody: Encodable {
    let provider: V2ClientPushEndpointProvider
    let environment: V2ClientPushEndpointEnvironment
    let token: String
}
