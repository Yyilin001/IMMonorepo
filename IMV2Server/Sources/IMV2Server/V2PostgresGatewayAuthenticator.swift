import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2GatewayAuthenticationError: Error, Equatable, Sendable {
    case invalidKeyMaterial
    case unauthenticated
    case corruptPersistenceState
}

/// HMAC key material comes from a secret manager/environment at composition
/// time; only an HMAC digest is persisted in PostgreSQL.
public struct V2AccessTokenHMACKey: Sendable {
    // Crypto's SymmetricKey is not Sendable. Retain immutable byte material
    // (which is Sendable) and build the short-lived Crypto value only at the
    // synchronous digest boundary.
    private let rawBytes: Data

    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayAuthenticationError.invalidKeyMaterial
        }
        rawBytes = bytes
    }

    public init(rawBytes: Data) throws {
        guard rawBytes.count >= 32 else { throw V2GatewayAuthenticationError.invalidKeyMaterial }
        self.rawBytes = rawBytes
    }

    public func digest(_ accessToken: String) -> String {
        let key = SymmetricKey(data: rawBytes)
        let code = HMAC<SHA256>.authenticationCode(for: Data(accessToken.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

/// Device-bound, revocation-aware authentication for the realtime gateway.
/// A successful lookup proves both the opaque token and the device supplied by
/// the TLS session; the protobuf payload is never allowed to name the user.
public struct V2PostgresGatewayAuthenticator: V2GatewayAuthenticator {
    private let database: any Database
    private let tokenKey: V2AccessTokenHMACKey
    private let now: @Sendable () -> Date

    public init(database: any Database, tokenKey: V2AccessTokenHMACKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.tokenKey = tokenKey
        self.now = now
    }

    public func authenticate(accessToken: String, deviceID: DeviceID) async throws -> UserID {
        guard !accessToken.isEmpty, let database = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        guard let deviceUUID = UUID(uuidString: deviceID.rawValue) else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        guard let row = try await database.raw("""
            SELECT token.user_id
            FROM im_v2.device_access_tokens AS token
            JOIN im_v2.auth_devices AS device
              ON device.user_id = token.user_id AND device.device_id = token.device_id
            WHERE token.token_hmac = \(bind: tokenKey.digest(accessToken))
              AND token.device_id = \(bind: deviceUUID)
              AND token.expires_at > \(bind: now())
              AND token.revoked_at IS NULL
              AND device.revoked_at IS NULL
            """).first(decoding: V2AuthenticatedUserRow.self)
        else { throw V2GatewayAuthenticationError.unauthenticated }
        guard let userID = try? UserID(row.userID.uuidString) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        // Activity is display metadata, never an authentication prerequisite.
        // Bound writes to once per minute so a busy foreground device cannot
        // turn account-edge reads into an unbounded write load.
        let observedAt = now()
        try? await database.raw("UPDATE im_v2.auth_devices SET last_active_at = \(bind: observedAt) WHERE device_id = \(bind: deviceUUID) AND (last_active_at IS NULL OR last_active_at < \(bind: observedAt.addingTimeInterval(-60)))").run()
        return userID
    }

    public func authenticatedSessionExpiresAt(accessToken: String, deviceID: DeviceID) async throws -> Date? {
        guard !accessToken.isEmpty, let database = database as? any SQLDatabase,
              let deviceUUID = UUID(uuidString: deviceID.rawValue)
        else { throw V2GatewayAuthenticationError.unauthenticated }
        guard let row = try await database.raw("""
            SELECT token.expires_at
            FROM im_v2.device_access_tokens AS token
            JOIN im_v2.auth_devices AS device
              ON device.user_id = token.user_id AND device.device_id = token.device_id
            WHERE token.token_hmac = \(bind: tokenKey.digest(accessToken))
              AND token.device_id = \(bind: deviceUUID)
              AND token.expires_at > \(bind: now())
              AND token.revoked_at IS NULL
              AND device.revoked_at IS NULL
            """).first(decoding: V2AuthenticatedExpiryRow.self)
        else { throw V2GatewayAuthenticationError.unauthenticated }
        return row.expiresAt
    }
}

private struct V2AuthenticatedUserRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
private struct V2AuthenticatedExpiryRow: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
