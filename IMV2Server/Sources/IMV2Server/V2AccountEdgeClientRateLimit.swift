import Crypto
import Foundation
import IMV2Core
import NIOCore

/// A network address supplied only by the authenticated HTTPS edge. It is
/// intentionally validated before it is turned into the opaque database key.
/// Account handlers never receive or log its clear-text form.
public struct V2AccountEdgeClientAddress: Equatable, Sendable {
    private let rawValue: String

    public init(_ value: String) throws {
        guard (1 ... 45).contains(value.utf8.count),
              (try? SocketAddress(ipAddress: value, port: 0)) != nil
        else { throw V2AccountEdgeClientRateLimitError.invalidAddress }
        rawValue = value
    }

    fileprivate var valueForKeyDerivation: String { rawValue }
}

/// Deployment-owned fixed-window budget for requests that have already
/// crossed the authenticated HTTPS account edge. There are deliberately no
/// source-code defaults: a production deployment must select a budget from
/// its approved abuse and recovery policy.
public struct V2AccountEdgeClientRateLimitPolicy: Equatable, Sendable {
    public let maximumRequests: Int
    public let window: TimeInterval

    public init(maximumRequests: Int, window: TimeInterval) throws {
        // PostgreSQL stores request_count as a signed 32-bit integer. Keep one
        // sentinel value above the configured budget so an over-budget
        // attempt can be represented without an overflow or a second query.
        guard maximumRequests > 0,
              maximumRequests < Int(Int32.max),
              window > 0
        else {
            throw V2AccountEdgeClientRateLimitError.invalidPolicy
        }
        self.maximumRequests = maximumRequests
        self.window = window
    }
}

public enum V2AccountEdgeClientRateLimitError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidKeyMaterial
    case invalidPolicy
    case unavailable
}

/// Pseudonymizes an edge-validated client address before the rate-limit store
/// sees it. The database holds only this HMAC digest, never an IP address.
public struct V2AccountEdgeClientRateLimitKey: Sendable {
    private let rawBytes: Data

    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2AccountEdgeClientRateLimitError.invalidKeyMaterial
        }
        rawBytes = bytes
    }

    public func digest(_ address: V2AccountEdgeClientAddress) -> String {
        digest("ip|" + address.valueForKeyDerivation)
    }

    /// Uses the same deployment key while keeping authenticated budgets in a
    /// separate namespace from IP budgets. The clear user/device identifiers
    /// never enter the rate-limit table.
    public func digest(
        identity: V2AuthenticatedConnection,
        scope: String
    ) throws -> String {
        guard !scope.isEmpty, scope.utf8.count <= 64,
              !scope.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2AccountEdgeClientRateLimitError.invalidPolicy }
        return digest(
            "auth|\(scope)|\(identity.userID.rawValue)|\(identity.deviceID.rawValue)"
        )
    }

    private func digest(_ value: String) -> String {
        let key = SymmetricKey(data: rawBytes)
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: key
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
