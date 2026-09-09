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
    private let activityWriteGate: V2DeviceActivityWriteGate

    public init(
        database: any Database,
        tokenKey: V2AccessTokenHMACKey,
        now: @escaping @Sendable () -> Date = Date.init,
        activityWriteGate: V2DeviceActivityWriteGate = .init()
    ) {
        self.database = database
        self.tokenKey = tokenKey
        self.now = now
        self.activityWriteGate = activityWriteGate
    }

    public func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        guard !accessToken.isEmpty, let database = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        guard let deviceUUID = UUID(uuidString: deviceID.rawValue) else {
            throw V2GatewayAuthenticationError.unauthenticated
        }
        let observedAt = now()
        guard v2PostgresTimestampCanEncode(observedAt) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard let row = try await database.raw("""
            SELECT token.user_id, LEAST(token.expires_at, device.session_expires_at) AS expires_at
            FROM im_v2.device_access_tokens AS token
            JOIN im_v2.auth_devices AS device
              ON device.user_id = token.user_id AND device.device_id = token.device_id
            WHERE token.token_hmac = \(bind: tokenKey.digest(accessToken))
              AND token.device_id = \(bind: deviceUUID)
              AND token.expires_at > \(bind: observedAt)
              AND token.revoked_at IS NULL
              AND device.revoked_at IS NULL
              AND device.session_expires_at > \(bind: observedAt)
              AND NOT EXISTS (
                  SELECT 1
                  FROM im_v2.special_accounts AS special
                  WHERE special.account_user_id = token.user_id
                    AND special.status = 'active'
              )
            """).first(decoding: V2AuthenticatedSessionRow.self)
        else { throw V2GatewayAuthenticationError.unauthenticated }
        let completedAt = now()
        guard v2PostgresTimestampCanEncode(completedAt),
              v2PostgresTimestampCanEncode(row.expiresAt) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        guard row.expiresAt > completedAt else { throw V2GatewayAuthenticationError.unauthenticated }
        guard let userID = try? UserID(row.userID.uuidString) else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        // This timestamp is presentation metadata, not authentication state.
        // The local gate removes repeated no-op UPDATE round trips; PostgreSQL's
        // predicate remains the cross-replica correctness boundary.
        if let activityCutoff = v2PostgresPastTimestamp(now: observedAt, interval: 60),
           await activityWriteGate.shouldWrite(deviceID: deviceID, at: observedAt) {
            try? await database.raw("""
                UPDATE im_v2.auth_devices
                SET last_active_at = \(bind: observedAt)
                WHERE user_id = \(bind: row.userID)
                  AND device_id = \(bind: deviceUUID)
                  AND (last_active_at IS NULL
                       OR last_active_at < \(bind: activityCutoff))
                """).run()
        }
        return .init(userID: userID, expiresAt: row.expiresAt)
    }
}

/// Process-local admission for best-effort device-activity writes. It changes
/// no authorization decision and periodically discards inactive device keys.
public actor V2DeviceActivityWriteGate {
    private let interval: TimeInterval
    private var nextEligibleAt: [DeviceID: Date] = [:]
    private var acceptedWrites = 0

    public init(interval: TimeInterval = 60) {
        self.interval = max(1, interval)
    }

    public func shouldWrite(deviceID: DeviceID, at now: Date) -> Bool {
        // A broken clock must not replace the next eligible write with an
        // unusable deadline that continues suppressing activity after recovery.
        guard let nextWriteAt = v2PostgresFutureTimestamp(now: now, interval: interval) else {
            return false
        }
        if let nextEligible = nextEligibleAt[deviceID], nextEligible > now {
            return false
        }
        nextEligibleAt[deviceID] = nextWriteAt
        acceptedWrites += 1
        if acceptedWrites.isMultiple(of: 1_024) {
            nextEligibleAt = nextEligibleAt.filter { $0.value > now }
        }
        return true
    }
}

private struct V2AuthenticatedSessionRow: Decodable {
    let userID: UUID
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case userID = "user_id", expiresAt = "expires_at" }
}
