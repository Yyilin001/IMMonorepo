import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// A single-use, account-factor result. The app passes it straight to the
/// device-credential issuer and never persists it in Keychain, a database, or
/// diagnostics.
public struct V2AccountAssertion: Equatable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2AccountAuthenticationError.invalidAssertion }
        self.value = value
    }
}

public enum V2AccountAuthenticationError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidAccountHandle
    case invalidPassword
    case invalidAssertion
    case invalidResponse
    case authenticationRejected
    case accountAlreadyExists
    case networkFailure
    case serverStatus(Int)
}

/// Password is deliberately accepted only as a short-lived function argument.
/// Callers must not retain it in observable state, UserDefaults, logs, or any
/// Keychain item.
public protocol V2PasswordAccountAuthenticating: Sendable {
    func register(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion
    func authenticate(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion
}

/// One-shot password hand-off used only by the fallback login action. The
/// supplied password is removed from the actor before the network request, so
/// retry requires an explicit new user action rather than retaining it in app
/// state. Swift cannot guarantee immediate memory zeroization for `String`,
/// but this prevents durable or observable retention.
public actor V2OneTimePasswordAccountAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    public enum Mode: Sendable { case register, authenticate }

    private let accountHandle: String
    private let authenticator: any V2PasswordAccountAuthenticating
    private let mode: Mode
    private var password: String?

    public init(
        accountHandle: String,
        password: String,
        mode: Mode = .authenticate,
        authenticator: any V2PasswordAccountAuthenticating
    ) {
        self.accountHandle = accountHandle
        self.password = password
        self.mode = mode
        self.authenticator = authenticator
    }

    public func accountAssertion() throws -> String {
        throw V2AccountAuthenticationError.authenticationRejected
    }

    public func accountAssertion(for deviceID: DeviceID) async throws -> String {
        guard let password else { throw V2AccountAuthenticationError.authenticationRejected }
        self.password = nil
        switch mode {
        case .register:
            return try await authenticator.register(accountHandle: accountHandle, password: password, deviceID: deviceID).value
        case .authenticate:
            return try await authenticator.authenticate(accountHandle: accountHandle, password: password, deviceID: deviceID).value
        }
    }
}

/// HTTPS adapter for the fallback password factor. It does not decide whether
/// password login is presented; that remains an app-level recovery choice.
public struct V2HTTPPasswordAccountAuthenticator: V2PasswordAccountAuthenticating, Sendable {
    private let registrationEndpoint: URL
    private let assertionEndpoint: URL
    private let transport: any V2AuthHTTPTransport

    public init(
        registrationEndpoint: URL,
        assertionEndpoint: URL,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()
    ) throws {
        guard Self.isHTTPS(registrationEndpoint), Self.isHTTPS(assertionEndpoint) else {
            throw V2AccountAuthenticationError.invalidEndpoint
        }
        self.registrationEndpoint = registrationEndpoint
        self.assertionEndpoint = assertionEndpoint
        self.transport = transport
    }

    public func register(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion {
        try await send(accountHandle: accountHandle, password: password, deviceID: deviceID, to: registrationEndpoint)
    }

    public func authenticate(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2AccountAssertion {
        try await send(accountHandle: accountHandle, password: password, deviceID: deviceID, to: assertionEndpoint)
    }

    private func send(accountHandle: String, password: String, deviceID: DeviceID, to endpoint: URL) async throws -> V2AccountAssertion {
        guard Self.isValidAccountHandle(accountHandle) else { throw V2AccountAuthenticationError.invalidAccountHandle }
        guard password.utf8.count >= 12, password.utf8.count <= 1_024 else { throw V2AccountAuthenticationError.invalidPassword }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(PasswordRequest(accountHandle: accountHandle, password: password, deviceID: deviceID.rawValue))
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw V2AccountAuthenticationError.networkFailure
        }
        switch response.statusCode {
        case 200 ... 299: break
        case 401: throw V2AccountAuthenticationError.authenticationRejected
        case 409: throw V2AccountAuthenticationError.accountAlreadyExists
        default: throw V2AccountAuthenticationError.serverStatus(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(AssertionResponse.self, from: data) else {
            throw V2AccountAuthenticationError.invalidResponse
        }
        return try V2AccountAssertion(body.accountAssertion)
    }

    private static func isHTTPS(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" && endpoint.host != nil
    }

    private static func isValidAccountHandle(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (3 ... 64).contains(scalars.count) && scalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0 == "_" || $0 == "-"
        }
    }
}

private struct PasswordRequest: Encodable {
    let accountHandle: String
    let password: String
    let deviceID: String
}

private struct AssertionResponse: Decodable {
    let accountAssertion: String
}
