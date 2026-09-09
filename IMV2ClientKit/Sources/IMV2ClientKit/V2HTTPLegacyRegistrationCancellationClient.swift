import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public struct V2LegacyDeviceRegistration: Codable, Equatable, Sendable {
    public let deviceID: DeviceID
    public let operationID: UUID

    public init(deviceID: DeviceID, operationID: UUID) throws {
        guard deviceID.uuidValue != nil else { throw V2LegacyRegistrationCancellationError.invalidRequest }
        self.deviceID = deviceID; self.operationID = operationID
    }
}

public enum V2LegacyRegistrationCancellationError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidRequest, invalidResponse, networkFailure
    case authenticationRequired, accountUnavailable, targetUnavailable, conflict, capacityExceeded
    case rateLimited(retryAfterSeconds: Int?)
    case serverStatus(Int)
}

public protocol V2LegacyRegistrationCancellationClient: Sendable {
    /// Returns only after an empty 204 confirms the exact legacy operation.
    func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws
}

/// Carries only the fresh factor and exact archived target. It has no access
/// to current login credentials and does not persist or retry the factor.
public struct V2HTTPLegacyRegistrationCancellationClient: V2LegacyRegistrationCancellationClient {
    private let endpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(endpoint: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw V2LegacyRegistrationCancellationError.invalidEndpoint }
        self.endpoint = endpoint; self.transport = transport
    }

    public func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws {
        try Task.checkCancellation()
        guard registration.deviceID.uuidValue != nil, assertionDeviceID.uuidValue != nil,
              registration.deviceID != assertionDeviceID,
              !accountAssertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountAssertion.utf8.count <= 4_096 else { throw V2LegacyRegistrationCancellationError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(Request(accountAssertion: accountAssertion,
            assertionDeviceID: assertionDeviceID.rawValue, targetDeviceID: registration.deviceID.rawValue, operationID: registration.operationID))
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2LegacyRegistrationCancellationError.networkFailure }
        try Task.checkCancellation()
        switch response.statusCode {
        case 204:
            guard data.isEmpty else { throw V2LegacyRegistrationCancellationError.invalidResponse }
        case 400: throw V2LegacyRegistrationCancellationError.invalidRequest
        case 401: throw V2LegacyRegistrationCancellationError.authenticationRequired
        case 403: throw V2LegacyRegistrationCancellationError.accountUnavailable
        case 404: throw V2LegacyRegistrationCancellationError.targetUnavailable
        case 409: throw V2LegacyRegistrationCancellationError.conflict
        case 507: throw V2LegacyRegistrationCancellationError.capacityExceeded
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw V2LegacyRegistrationCancellationError.rateLimited(retryAfterSeconds: delay)
        default: throw V2LegacyRegistrationCancellationError.serverStatus(response.statusCode)
        }
    }

    private struct Request: Encodable {
        let accountAssertion: String
        let assertionDeviceID: String
        let targetDeviceID: String
        let operationID: UUID
    }
}
