import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public enum V2DeviceRevocationResult: Equatable, Sendable {
    case revoked
    /// The server recognized the capability, but its redemption deadline ended.
    /// This is distinct from confirmation that revocation was committed.
    case expired
    case invalidCredential
    case operationConflict
}

public protocol V2DeviceRevocationClient: Sendable {
    func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationResult
}

public enum V2DeviceRevocationClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case networkFailure
    case rateLimited(retryAfterSeconds: Int?)
    case serverStatus(Int)
}

/// Accepts only the old session's purpose-limited proof. It has no reference to
/// V2AuthSession, so a retry cannot refresh or borrow another account's token.
public struct V2HTTPDeviceRevocationClient: V2DeviceRevocationClient {
    private let endpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2DeviceRevocationClientError.invalidEndpoint }
        self.endpoint = endpoint
        self.transport = transport
    }

    public func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationResult {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(Body(credential: credential, operationID: operationID))
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2DeviceRevocationClientError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204:
            guard data.isEmpty else { throw V2DeviceRevocationClientError.invalidResponse }
            return .revoked
        case 401: return .invalidCredential
        case 410: return .expired
        case 409: return .operationConflict
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2DeviceRevocationClientError.rateLimited(retryAfterSeconds: seconds)
        default: throw V2DeviceRevocationClientError.serverStatus(response.statusCode)
        }
    }

    private struct Body: Encodable {
        let credential: V2DeviceRevocationCredential
        let operationID: UUID
    }
}
