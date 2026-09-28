import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2PersonalPreferenceRecovering: Sendable {
    func recover(_ request: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult
}

public struct V2HTTPPersonalPreferenceRecoveryClient: V2PersonalPreferenceRecovering, Sendable {
    private let roomsEndpoint: URL
    private let credentials: any V2ClientPushEndpointCredentialProvider
    private let transport: any V2ClientPushEndpointHTTPTransport
    public init(roomsEndpoint: URL, credentials: any V2ClientPushEndpointCredentialProvider,
                transport: any V2ClientPushEndpointHTTPTransport) throws {
        guard roomsEndpoint.scheme?.lowercased() == "https", roomsEndpoint.host != nil,
              roomsEndpoint.user == nil, roomsEndpoint.password == nil, roomsEndpoint.fragment == nil,
              roomsEndpoint.query == nil else { throw V2OwnProfileClientError.invalidEndpoint }
        self.roomsEndpoint = roomsEndpoint; self.credentials = credentials; self.transport = transport
    }
    public func recover(_ input: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult {
        try Task.checkCancellation()
        let credential = try await credentials.pushEndpointCredentials()
        let endpoint = roomsEndpoint.appendingPathComponent(input.roomID.rawValue).appendingPathComponent("personal-preferences/operations/recover")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(input)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw V2HTTPFailure.status(response, service: "personal-preferences") }
        guard V2HTTPContract.isJSON(response),
              let result = try? JSONDecoder().decode(V2PersonalPreferenceRecoveryResult.self, from: data) else { throw V2OwnProfileClientError.invalidResponse }
        if case .receipt(let receipt) = result {
            guard receipt.identity == input.identity, receipt.fingerprint == input.fingerprint else { throw V2OperationWorkError.identityConflict }
        }
        return result
    }
}
