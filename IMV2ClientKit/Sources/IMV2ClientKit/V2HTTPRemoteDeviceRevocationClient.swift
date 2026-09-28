import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2RemoteDeviceRevocationClient: Sendable {
    func baseline() async throws -> V2RemoteDeviceRevocationBaseline
    func submit(_ command: V2RemoteDeviceRevocationCommand) async throws -> V2RemoteDeviceRevocationResult
    func recover(_ command: V2RemoteDeviceRevocationCommand, action: V2RemoteDeviceRevocationRecoveryRequest.Action) async throws -> V2RemoteDeviceRevocationResult
}
public struct V2HTTPRemoteDeviceRevocationClient: V2RemoteDeviceRevocationClient {
    private let baseURL: URL
    private let credentials: any V2ClientDeviceSessionCredentialProvider
    private let transport: any V2ClientDeviceSessionHTTPTransport
    public init(baseURL: URL, credentials: any V2ClientDeviceSessionCredentialProvider, transport: any V2ClientDeviceSessionHTTPTransport) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw V2ClientDeviceSessionError.invalidEndpoint }
        self.baseURL = baseURL; self.credentials = credentials; self.transport = transport
    }
    public func baseline() async throws -> V2RemoteDeviceRevocationBaseline {
        let bytes = try await send(path: "v2/devices/revocation-baseline", body: nil)
        return try JSONDecoder().decode(V2RemoteDeviceRevocationBaseline.self, from: bytes)
    }
    public func submit(_ command: V2RemoteDeviceRevocationCommand) async throws -> V2RemoteDeviceRevocationResult {
        try await result(command, path: "v2/devices/remote-revocations/submit", body: JSONEncoder().encode(command))
    }
    public func recover(_ command: V2RemoteDeviceRevocationCommand, action: V2RemoteDeviceRevocationRecoveryRequest.Action) async throws -> V2RemoteDeviceRevocationResult {
        try await result(command, path: "v2/devices/remote-revocations/operations/recover", body: JSONEncoder().encode(V2RemoteDeviceRevocationRecoveryRequest(command: command, action: action)))
    }
    private func result(_ command: V2RemoteDeviceRevocationCommand, path: String, body: Data) async throws -> V2RemoteDeviceRevocationResult {
        let bytes = try await send(path: path, body: body)
        let result = try JSONDecoder().decode(V2RemoteDeviceRevocationResult.self, from: bytes)
        if case .receipt(let receipt) = result, !receipt.validates(command) { throw V2RemoteDeviceRevocationValidationError.invalidReceipt }
        return result
    }
    private func send(path: String, body: Data?) async throws -> Data {
        guard (body?.count ?? 0) <= 32_768 else { throw V2ClientDeviceSessionError.invalidRequest }
        try Task.checkCancellation()
        let credential = try await credentials.deviceSessionCredentials()
        try Task.checkCancellation()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientDeviceSessionError.authorizationUnavailable }
        var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw V2HTTPFailure.status(response, service: "deviceSessions") }
        guard data.count <= 65_536, V2HTTPContract.isJSON(response) else { throw V2ClientDeviceSessionError.invalidResponse }
        return data
    }
}
