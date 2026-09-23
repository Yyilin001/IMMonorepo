import Crypto
import FluentKit
import Foundation
import IMV2Core
import SQLKit

public enum V2PasswordLifecycleError: Error, Equatable, Sendable {
    case rejected, invalidInput, unavailable
    case rateLimited(Int)
}

public protocol V2PasswordLifecycleManaging: Sendable {
    func setRecoveryCode(accountHandle: String, password: String, recoveryCode: String, deviceID: DeviceID) async throws
    func changePassword(accountHandle: String, currentPassword: String, newPassword: String, deviceID: DeviceID) async throws
    func resetPassword(accountHandle: String, recoveryCode: String, newPassword: String, deviceID: DeviceID) async throws
}

/// Password changes and offline recovery share the account-state lock with device issuance.
/// No password, recovery code, or resulting secret is retained in audit or operation records.
public struct V2PasswordLifecycleService: V2PasswordLifecycleManaging {
    private let database: any Database
    private let passwords: any V2PasswordHashing
    private let limiter: any V2PasswordLoginAttemptLimiting
    private let recoveryKey: V2AccessTokenHMACKey

    public init(database: any Database, passwords: any V2PasswordHashing,
                limiter: any V2PasswordLoginAttemptLimiting, recoveryKey: V2AccessTokenHMACKey) {
        self.database = database
        self.passwords = passwords
        self.limiter = limiter
        self.recoveryKey = recoveryKey
    }

    /// Replace a recovery code only after verifying the current password. The client generates
    /// and saves the new code before sending it, so a lost response cannot lose the only copy.
    public func setRecoveryCode(accountHandle: String, password: String, recoveryCode: String, deviceID: DeviceID) async throws {
        guard Self.validRecoveryCode(recoveryCode) else { throw V2PasswordLifecycleError.invalidInput }
        let expected = try await verifyPassword(accountHandle: accountHandle, password: password, deviceID: deviceID)
        try await mutate(accountHandle: accountHandle, expected: expected, deviceID: deviceID,
                         newPasswordHash: nil, recoveryHMAC: recoveryKey.digest("v2-recovery|" + recoveryCode), expectedRecoveryHMAC: nil)
    }

    public func changePassword(accountHandle: String, currentPassword: String, newPassword: String, deviceID: DeviceID) async throws {
        guard V2PasswordHashPolicy.accepts(newPassword), currentPassword != newPassword else { throw V2PasswordLifecycleError.invalidInput }
        let expected = try await verifyPassword(accountHandle: accountHandle, password: currentPassword, deviceID: deviceID)
        let hash = try await passwords.hash(newPassword)
        try await mutate(accountHandle: accountHandle, expected: expected, deviceID: deviceID,
                         newPasswordHash: hash, recoveryHMAC: nil, expectedRecoveryHMAC: nil)
    }

    /// A successful reset consumes the recovery code and revokes every device, including
    /// the device submitting this request. A fresh login is always required afterwards.
    public func resetPassword(accountHandle: String, recoveryCode: String, newPassword: String, deviceID: DeviceID) async throws {
        guard Self.validRecoveryCode(recoveryCode), V2PasswordHashPolicy.accepts(newPassword) else { throw V2PasswordLifecycleError.invalidInput }
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else { throw V2PasswordLifecycleError.unavailable }
        // Recovery codes have 256 random bits; do not share the password lockout, otherwise
        // an attacker could prevent recovery simply by submitting incorrect passwords.
        // The trusted edge's shared address budget still applies to this endpoint.
        let row = try await sql.raw("SELECT user_id, password_hash, credential_revision, recovery_code_hmac FROM im_v2.account_password_credentials WHERE account_handle = \(bind: handle)").first(decoding: Credential.self)
        let incoming = recoveryKey.digest("v2-recovery|" + recoveryCode)
        guard let row, let stored = row.recoveryHMAC,
              recoveryKey.matches(stored, value: "v2-recovery|" + recoveryCode) else {
            try await limiter.auditRejectedAttempt(accountHandle: handle, userID: row.map { .init(uuid: $0.userID) }, deviceID: deviceID)
            throw V2PasswordLifecycleError.rejected
        }
        let hash = try await passwords.hash(newPassword)
        try await mutate(accountHandle: handle, expected: .init(userID: .init(uuid: row.userID), passwordHash: row.passwordHash, revision: row.revision),
                         deviceID: deviceID, newPasswordHash: hash, recoveryHMAC: nil, expectedRecoveryHMAC: incoming)
    }

    public static func validRecoveryCode(_ code: String) -> Bool {
        code.utf8.count == 64 && code.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func verifyPassword(accountHandle: String, password: String, deviceID: DeviceID) async throws -> V2PasswordCredential {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordLifecycleError.invalidInput }
        if let retry = try await limiter.consumeAttempt(accountHandle: accountHandle) { throw V2PasswordLifecycleError.rateLimited(retry) }
        let expected = try await V2PostgresPasswordAccountStore(database: database).passwordCredential(for: accountHandle)
        let matches = try await passwords.verify(password, created: expected?.passwordHash ?? V2PasswordHashPolicy.dummyDigest)
        guard let expected, matches else {
            try await limiter.auditRejectedAttempt(accountHandle: accountHandle, userID: expected?.userID, deviceID: deviceID)
            throw V2PasswordLifecycleError.rejected
        }
        return expected
    }

    private func mutate(accountHandle: String, expected: V2PasswordCredential, deviceID: DeviceID,
                        newPasswordHash: String?, recoveryHMAC: String?, expectedRecoveryHMAC: String?) async throws {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let user = expected.userID.uuidValue else { throw V2PasswordLifecycleError.unavailable }
        try Task.checkCancellation()
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PasswordLifecycleError.unavailable }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "account-state:" + user.uuidString), 0))").run()
            try await v2LockPasswordAttempts(sql, handle: handle)
            guard let row = try await sql.raw("SELECT user_id, password_hash, credential_revision, recovery_code_hmac FROM im_v2.account_password_credentials WHERE account_handle = \(bind: handle) FOR UPDATE").first(decoding: Credential.self),
                  row.userID == user, row.passwordHash == expected.passwordHash, row.revision == expected.revision,
                  expectedRecoveryHMAC.map({ $0 == row.recoveryHMAC }) ?? true,
                  try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: user)").first() == nil,
                  try await sql.raw("SELECT 1 FROM im_v2.special_accounts WHERE account_user_id = \(bind: user) AND status = 'active'").first() == nil else { throw V2PasswordLifecycleError.rejected }
            if let newPasswordHash {
                guard row.revision < Int64.max else { throw V2PasswordLifecycleError.unavailable }
                try await sql.raw("UPDATE im_v2.account_password_credentials SET password_hash = \(bind: newPasswordHash), credential_revision = credential_revision + 1, recovery_code_hmac = NULL WHERE user_id = \(bind: user)").run()
                try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, clock_timestamp()) WHERE user_id = \(bind: user)").run()
                try await sql.raw("UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, clock_timestamp()) WHERE user_id = \(bind: user)").run()
                try await sql.raw("UPDATE im_v2.device_refresh_sessions SET revoked_at = COALESCE(revoked_at, clock_timestamp()) WHERE user_id = \(bind: user)").run()
                try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) SELECT user_id, device_id, clock_timestamp() FROM im_v2.auth_devices WHERE user_id = \(bind: user) ON CONFLICT (device_id) DO NOTHING").run()
            } else {
                try await sql.raw("UPDATE im_v2.account_password_credentials SET recovery_code_hmac = \(bind: recoveryHMAC) WHERE user_id = \(bind: user)").run()
            }
            try await sql.raw("DELETE FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").run()
            // Only a bounded action name and opaque identities enter this audit.
            try await sql.raw("INSERT INTO im_v2.account_password_authentication_audit (event_id, outcome, user_id, device_id, occurred_at) VALUES (\(bind: UUID()), \(bind: newPasswordHash == nil ? "recovery_code_changed" : expectedRecoveryHMAC == nil ? "password_changed" : "password_recovered"), \(bind: user), \(bind: deviceID.uuidValue), clock_timestamp())").run()
        }
    }
}

private struct Credential: Decodable {
    let userID: UUID
    let passwordHash: String
    let revision: Int64
    let recoveryHMAC: String?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", passwordHash = "password_hash", revision = "credential_revision", recoveryHMAC = "recovery_code_hmac"
    }
}
