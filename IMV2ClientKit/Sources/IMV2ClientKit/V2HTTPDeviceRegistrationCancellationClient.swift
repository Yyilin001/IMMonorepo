import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public enum V2DeviceRegistrationCancellationResult: Equatable, Sendable {
    /// The registration is durably cancelled, including any session it issued.
    case cancelled
    /// No future issue is permitted, or the bound session deadline has ended.
    /// This is not confirmation that this request committed a revocation.
    case expired
}

public enum V2DeviceRegistrationCancellationClientError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidResponse, networkFailure
    case rateLimited(retryAfterSeconds: Int?)
    case serverStatus(Int)
}

public protocol V2DeviceRegistrationCancellationClient: Sendable {
    func cancel(_ registration: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationResult
}

/// Uses only the exact pre-issuance proof. No account credentials or refresh
/// dependency are available to this transport, including during later retries.
public struct V2HTTPDeviceRegistrationCancellationClient: V2DeviceRegistrationCancellationClient {
    private let endpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2DeviceRegistrationCancellationClientError.invalidEndpoint }
        self.endpoint = endpoint; self.transport = transport
    }

    public func cancel(_ registration: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationResult {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(registration)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2DeviceRegistrationCancellationClientError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204, 410:
            guard data.isEmpty else { throw V2DeviceRegistrationCancellationClientError.invalidResponse }
            return response.statusCode == 204 ? .cancelled : .expired
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2DeviceRegistrationCancellationClientError.rateLimited(retryAfterSeconds: delay)
        default: throw V2DeviceRegistrationCancellationClientError.serverStatus(response.statusCode)
        }
    }
}
