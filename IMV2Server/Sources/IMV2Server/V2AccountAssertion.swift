import Crypto
import Foundation
import IMV2Core

public enum V2AccountAssertionError: Error, Equatable, Sendable {
    case invalidKeyMaterial
    case invalidLifetime
    case invalidAssertion
}

/// Short-lived account-factor result, bound to the exact V2 device that is
/// about to be registered. It is signed rather than encrypted because it
/// contains only opaque UUIDs and timestamps; it is never logged or retained
/// by the mobile client after handing it to the device-credential boundary.
public struct V2HMACAccountAssertionIssuer: V2DeviceBoundAccountAssertionVerifier, Sendable {
    private let rawKey: Data
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        base64EncodedKey: String,
        lifetime: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let key = Data(base64Encoded: base64EncodedKey), key.count >= 32 else {
            throw V2AccountAssertionError.invalidKeyMaterial
        }
        try self.init(rawKey: key, lifetime: lifetime, now: now)
    }

    public init(
        rawKey: Data,
        lifetime: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard rawKey.count >= 32 else { throw V2AccountAssertionError.invalidKeyMaterial }
        guard lifetime > 0, lifetime <= 5 * 60, lifetime.isFinite else { throw V2AccountAssertionError.invalidLifetime }
        self.rawKey = rawKey
        self.lifetime = lifetime
        self.now = now
    }

    public func issue(userID: UserID, deviceID: DeviceID) throws -> String {
        let issuedAt = now()
        let claims = Claims(
            userID: userID.rawValue,
            deviceID: deviceID.rawValue,
            expiresAtMilliseconds: Int64((issuedAt.addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000).rounded(.towardZero))
        )
        let payload = try JSONEncoder().encode(claims)
        let encodedPayload = base64URL(payload)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(encodedPayload.utf8), using: SymmetricKey(data: rawKey))
        return "v2a1.\(encodedPayload).\(base64URL(Data(signature)))"
    }

    public func verifiedUserID(for accountAssertion: String) throws -> UserID {
        try verifiedClaims(for: accountAssertion, expectedDeviceID: nil)
    }

    public func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) throws -> UserID {
        try verifiedClaims(for: accountAssertion, expectedDeviceID: deviceID)
    }

    private func verifiedClaims(for assertion: String, expectedDeviceID: DeviceID?) throws -> UserID {
        guard assertion.utf8.count <= 4_096 else { throw V2AccountAssertionError.invalidAssertion }
        let parts = assertion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v2a1",
              let payload = decodeBase64URL(String(parts[1])),
              let signature = decodeBase64URL(String(parts[2])),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(parts[1].utf8), using: SymmetricKey(data: rawKey)),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              let userID = try? UserID(claims.userID),
              let assertionDeviceID = try? DeviceID(claims.deviceID)
        else { throw V2AccountAssertionError.invalidAssertion }
        let nowMilliseconds = now().timeIntervalSince1970 * 1_000
        guard nowMilliseconds.isFinite,
              Double(claims.expiresAtMilliseconds) > nowMilliseconds,
              expectedDeviceID.map({ $0 == assertionDeviceID }) ?? true
        else { throw V2AccountAssertionError.invalidAssertion }
        return userID
    }
}

private struct Claims: Codable, Sendable {
    let userID: String
    let deviceID: String
    let expiresAtMilliseconds: Int64
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func decodeBase64URL(_ value: String) -> Data? {
    var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
    return Data(base64Encoded: padded)
}
