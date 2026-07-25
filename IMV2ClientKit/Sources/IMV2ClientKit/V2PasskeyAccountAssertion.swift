import Foundation
import IMV2Core

/// The server creates this one-time challenge and associates its opaque ID
/// with the account-authentication ceremony. Raw challenge bytes never need
/// to be interpreted by views.
public struct V2PasskeyAssertionRequest: Equatable, Sendable {
    public let challengeID: String
    public let challenge: Data
    public let relyingPartyID: String
    public let allowedCredentialIDs: [Data]

    public init(challengeID: String, challenge: Data, relyingPartyID: String, allowedCredentialIDs: [Data]) throws {
        guard !challengeID.isEmpty, !challenge.isEmpty,
              !relyingPartyID.isEmpty, !relyingPartyID.contains("/")
        else { throw V2PasskeyAccountAssertionError.invalidRequest }
        self.challengeID = challengeID
        self.challenge = challenge
        self.relyingPartyID = relyingPartyID
        self.allowedCredentialIDs = allowedCredentialIDs
    }
}

public struct V2PasskeyAssertionResult: Equatable, Sendable {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?

    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) throws {
        guard !credentialID.isEmpty, !clientDataJSON.isEmpty, !authenticatorData.isEmpty, !signature.isEmpty else {
            throw V2PasskeyAccountAssertionError.invalidResult
        }
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

public enum V2PasskeyAccountAssertionError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case invalidResult
    case invalidResponse
    case authenticationRejected
    case unavailable
    case networkFailure
    case serverStatus(Int)
}

public protocol V2PasskeyAssertionRequestProviding: Sendable {
    func assertionRequest(accountHandle: String?, deviceID: DeviceID) async throws -> V2PasskeyAssertionRequest
}

public protocol V2PasskeyAuthorizing: Sendable {
    func authorize(_ request: V2PasskeyAssertionRequest) async throws -> V2PasskeyAssertionResult
}

public protocol V2PasskeyAssertionSubmitting: Sendable {
    func submit(_ result: V2PasskeyAssertionResult, for request: V2PasskeyAssertionRequest) async throws -> V2AccountAssertion
}

/// The primary account-factor adapter. It acquires a fresh passkey assertion
/// for every device-credential registration attempt and deliberately retains
/// neither the WebAuthn response nor the resulting account assertion.
public struct V2PasskeyAccountAssertionProvider: V2DeviceBoundAccountAssertionProvider, Sendable {
    private let accountHandle: String?
    private let requestProvider: any V2PasskeyAssertionRequestProviding
    private let authorizer: any V2PasskeyAuthorizing
    private let submitter: any V2PasskeyAssertionSubmitting

    public init(
        accountHandle: String? = nil,
        requestProvider: any V2PasskeyAssertionRequestProviding,
        authorizer: any V2PasskeyAuthorizing,
        submitter: any V2PasskeyAssertionSubmitting
    ) {
        self.accountHandle = accountHandle
        self.requestProvider = requestProvider
        self.authorizer = authorizer
        self.submitter = submitter
    }

    public func accountAssertion() async throws -> String {
        throw V2PasskeyAccountAssertionError.unavailable
    }

    public func accountAssertion(for deviceID: DeviceID) async throws -> String {
        let request = try await requestProvider.assertionRequest(accountHandle: accountHandle, deviceID: deviceID)
        let result = try await authorizer.authorize(request)
        let assertion = try await submitter.submit(result, for: request)
        return assertion.value
    }
}

/// HTTP portion of the WebAuthn assertion ceremony. The server alone owns
/// challenge lifecycle, RP-ID validation, signature verification, counters,
/// and issuing the short-lived V2 account assertion.
public struct V2HTTPPasskeyAssertionService: V2PasskeyAssertionRequestProviding, V2PasskeyAssertionSubmitting, Sendable {
    private let optionsEndpoint: URL
    private let completionEndpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(
        optionsEndpoint: URL,
        completionEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard Self.isHTTPS(optionsEndpoint), Self.isHTTPS(completionEndpoint) else {
            throw V2PasskeyAccountAssertionError.invalidEndpoint
        }
        self.optionsEndpoint = optionsEndpoint
        self.completionEndpoint = completionEndpoint
        self.transport = transport
    }

    public func assertionRequest(accountHandle: String?, deviceID: DeviceID) async throws -> V2PasskeyAssertionRequest {
        var request = try request(url: optionsEndpoint, body: PasskeyOptionsRequest(accountHandle: accountHandle, deviceID: deviceID.rawValue))
        request.httpMethod = "POST"
        let data = try await execute(request)
        guard let body = try? JSONDecoder().decode(PasskeyOptionsResponse.self, from: data),
              let challenge = Self.decodeBase64URL(body.challenge),
              let allowed = body.allowedCredentialIDs.map({ values in values.compactMap(Self.decodeBase64URL) }),
              allowed.count == body.allowedCredentialIDs?.count
        else { throw V2PasskeyAccountAssertionError.invalidResponse }
        return try .init(challengeID: body.challengeID, challenge: challenge, relyingPartyID: body.relyingPartyID, allowedCredentialIDs: allowed)
    }

    public func submit(_ result: V2PasskeyAssertionResult, for request: V2PasskeyAssertionRequest) async throws -> V2AccountAssertion {
        var httpRequest = try self.request(
            url: completionEndpoint,
            body: PasskeyCompletionRequest(
                challengeID: request.challengeID,
                credentialID: Self.base64URL(result.credentialID),
                clientDataJSON: Self.base64URL(result.clientDataJSON),
                authenticatorData: Self.base64URL(result.authenticatorData),
                signature: Self.base64URL(result.signature),
                userHandle: result.userHandle.map(Self.base64URL)
            )
        )
        httpRequest.httpMethod = "POST"
        let data = try await execute(httpRequest)
        guard let body = try? JSONDecoder().decode(PasskeyCompletionResponse.self, from: data) else {
            throw V2PasskeyAccountAssertionError.invalidResponse
        }
        return try V2AccountAssertion(body.accountAssertion)
    }

    private func request<Body: Encodable>(url: URL, body: Body) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2PasskeyAccountAssertionError.networkFailure
        }
        switch response.statusCode {
        case 200 ... 299: return data
        case 401, 403: throw V2PasskeyAccountAssertionError.authenticationRejected
        default: throw V2PasskeyAccountAssertionError.serverStatus(response.statusCode)
        }
    }

    private static func isHTTPS(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" && endpoint.host != nil
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct PasskeyOptionsRequest: Encodable { let accountHandle: String?; let deviceID: String }
private struct PasskeyOptionsResponse: Decodable {
    let challengeID: String
    let challenge: String
    let relyingPartyID: String
    let allowedCredentialIDs: [String]?
}
private struct PasskeyCompletionRequest: Encodable {
    let challengeID: String
    let credentialID: String
    let clientDataJSON: String
    let authenticatorData: String
    let signature: String
    let userHandle: String?
}
private struct PasskeyCompletionResponse: Decodable { let accountAssertion: String }
