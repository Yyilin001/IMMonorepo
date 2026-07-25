import Crypto
import Foundation
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Narrow transport boundary so the APNs adapter can be tested without a live
/// provider. Request bodies are generic wake payloads and must never be logged.
public struct V2PushHTTPRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct V2PushHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol V2PushHTTPClient: Sendable {
    func execute(_ request: V2PushHTTPRequest) async throws -> V2PushHTTPResponse
}

public struct V2URLSessionPushHTTPClient: V2PushHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: V2PushHTTPRequest) async throws -> V2PushHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw V2APNSPushProviderError.invalidResponse }
        return .init(statusCode: http.statusCode, body: body)
    }
}

public protocol V2APNSAuthorizer: Sendable {
    func authorizationValue(now: Date) throws -> String
}

/// ES256 token authorizer for APNs. The private key arrives from secret
/// management as the 32-byte P-256 raw private representation, base64 encoded;
/// it is never persisted or logged by this process.
public struct V2APNSJWTAuthorizer: V2APNSAuthorizer {
    private let teamID: String
    private let keyID: String
    private let privateKeyRaw: Data

    public init(teamID: String, keyID: String, privateKeyRawBase64: String) throws {
        let normalizedTeamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTeamID.isEmpty, !normalizedKeyID.isEmpty,
              let privateKeyRaw = Data(base64Encoded: privateKeyRawBase64),
              privateKeyRaw.count == 32
        else { throw V2APNSPushProviderError.invalidConfiguration }
        self.teamID = normalizedTeamID
        self.keyID = normalizedKeyID
        self.privateKeyRaw = privateKeyRaw
    }

    public func authorizationValue(now: Date) throws -> String {
        let header = try jsonBase64URL(["alg": "ES256", "kid": keyID])
        let issuedAt = now.timeIntervalSince1970
        guard issuedAt.isFinite, issuedAt >= 0, issuedAt <= Double(Int64.max) else {
            throw V2APNSPushProviderError.invalidConfiguration
        }
        let claims = try jsonBase64URL(["iss": teamID, "iat": Int64(issuedAt.rounded(.towardZero))])
        let signingInput = "\(header).\(claims)"
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "bearer \(signingInput).\(base64URL(signature.rawRepresentation))"
    }
}

public enum V2APNSPushProviderError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case providerRejected
}

/// Sends APNs background wakes only. The payload deliberately has no alert,
/// title, room, message, sender, attachment, token, or synchronization data.
/// APNs terminal device-token failures disable only the observed endpoint
/// generation and terminally suppress only that generic wake.
public struct V2APNSPushWakeProvider: V2PushWakeProvider {
    private let endpointStore: any V2PushDeviceEndpointStore
    private let httpClient: any V2PushHTTPClient
    private let authorizer: any V2APNSAuthorizer
    private let topic: String
    private let now: @Sendable () -> Date

    public init(
        endpointStore: any V2PushDeviceEndpointStore,
        httpClient: any V2PushHTTPClient,
        authorizer: any V2APNSAuthorizer,
        topic: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let normalizedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTopic.isEmpty, normalizedTopic.utf8.count <= 255 else {
            throw V2APNSPushProviderError.invalidConfiguration
        }
        self.endpointStore = endpointStore
        self.httpClient = httpClient
        self.authorizer = authorizer
        self.topic = normalizedTopic
        self.now = now
    }

    public func send(_ wake: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome {
        guard let endpoint = try await endpointStore.endpoint(for: wake.deviceID) else {
            return .suppressed(.endpointUnavailable)
        }
        guard endpoint.provider == .apns, validAPNSToken(endpoint.token),
              let url = endpointURL(for: endpoint)
        else {
            try await endpointStore.disable(endpoint, now: now())
            return .suppressed(.endpointRejected)
        }
        let authorization = try authorizer.authorizationValue(now: now())
        let request = V2PushHTTPRequest(
            url: url,
            headers: [
                "authorization": authorization,
                "apns-topic": topic,
                "apns-push-type": "background",
                "apns-priority": "5",
                "content-type": "application/json",
            ],
            body: Data(#"{"aps":{"content-available":1}}"#.utf8)
        )
        let response = try await httpClient.execute(request)
        if (200...299).contains(response.statusCode) {
            return .sent
        }
        if isTerminalEndpointRejection(statusCode: response.statusCode, body: response.body) {
            try await endpointStore.disable(endpoint, now: now())
            return .suppressed(.endpointRejected)
        }
        throw V2APNSPushProviderError.providerRejected
    }

    private func endpointURL(for endpoint: V2PushDeviceEndpoint) -> URL? {
        let host: String
        switch endpoint.environment {
        case .development: host = "https://api.sandbox.push.apple.com"
        case .production: host = "https://api.push.apple.com"
        }
        return URL(string: "\(host)/3/device/\(endpoint.token)")
    }

    private func validAPNSToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    private func isTerminalEndpointRejection(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 400 || statusCode == 410,
              let response = try? JSONDecoder().decode(APNSErrorBody.self, from: body)
        else { return false }
        return ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(response.reason)
    }
}

private struct APNSErrorBody: Decodable {
    let reason: String
}

private func jsonBase64URL(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return base64URL(data)
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
