import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
#if canImport(Security)
import Security
#endif

public enum V2PasswordLifecycleAction: String, Sendable {
    case change, recoveryCode = "recovery-code", recover
}

/// Explicit user operations only; no automatic retry and no persistent secret storage.
public struct V2PasswordLifecycleClient: Sendable {
    private let baseURL: URL
    private let transport: any V2AuthHTTPTransport
    public init(baseURL: URL, transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport()) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw V2AccountAuthenticationError.invalidEndpoint
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    public func perform(_ action: V2PasswordLifecycleAction, accountHandle: String, deviceID: DeviceID,
                        currentPassword: String? = nil, newPassword: String? = nil, recoveryCode: String? = nil) async throws {
        func validPassword(_ value: String?) -> Bool {
            value.map { (12...1024).contains($0.utf8.count) && !$0.utf8.contains(0) } ?? false
        }
        guard action == .recover || validPassword(currentPassword),
              action == .recoveryCode || validPassword(newPassword) else { throw V2AccountAuthenticationError.invalidPassword }
        if action != .change {
            guard let recoveryCode, recoveryCode.utf8.count == 64,
                  recoveryCode.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw V2AccountAuthenticationError.invalidRecoveryCode
            }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(action.rawValue), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = try JSONEncoder().encode(Input(accountHandle: accountHandle, deviceID: deviceID.rawValue,
            currentPassword: currentPassword, newPassword: newPassword, recoveryCode: recoveryCode))
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw V2AccountAuthenticationError.networkFailure }
        switch response.statusCode {
        case 204 where data.isEmpty: return
        case 204: throw V2AccountAuthenticationError.invalidResponse
        case 401: throw V2AccountAuthenticationError.authenticationRejected
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw V2AccountAuthenticationError.rateLimited(retryAfterSeconds: seconds.flatMap { $0 > 0 ? $0 : nil })
        default: throw V2AccountAuthenticationError.serverStatus(response.statusCode)
        }
    }

    /// 256-bit random secret. Show only in the explicit recovery-code setup UI.
    public static func generateRecoveryCode() throws -> String {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw V2AccountAuthenticationError.invalidResponse
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
        #else
        throw V2AccountAuthenticationError.invalidResponse
        #endif
    }

    private struct Input: Encodable {
        let accountHandle: String
        let deviceID: String
        let currentPassword: String?
        let newPassword: String?
        let recoveryCode: String?
    }
}
