import Foundation
import IMV2Core
import SQLKit

/// Durable, privacy-minimized outcomes for the password fallback factor.
/// The audit record never contains an account handle, a password, a password
/// hash, an assertion, or a network-derived client identity.
enum V2PasswordAuthenticationAuditOutcome: String, Sendable {
    case registrationSucceeded = "registration_succeeded"
    case assertionSucceeded = "assertion_succeeded"
    case assertionRejected = "assertion_rejected"
}

enum V2PasswordAuthenticationAuditError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidTimestamp
}

func recordPasswordAuthenticationAudit(
    outcome: V2PasswordAuthenticationAuditOutcome,
    userID: UserID?,
    deviceID: DeviceID,
    occurredAt: Date,
    on sql: any SQLDatabase
) async throws {
    guard let timestamp = try? V2PostgresTimestamp(date: occurredAt) else {
        throw V2PasswordAuthenticationAuditError.invalidTimestamp
    }
    try await recordPasswordAuthenticationAudit(outcome: outcome, userID: userID,
        deviceID: deviceID, occurredAt: timestamp, on: sql)
}

func recordPasswordAuthenticationAudit(
    outcome: V2PasswordAuthenticationAuditOutcome,
    userID: UserID?,
    deviceID: DeviceID,
    occurredAt: V2PostgresTimestamp,
    on sql: any SQLDatabase
) async throws {
    guard let deviceUUID = UUID(uuidString: deviceID.rawValue) else {
        throw V2PasswordAuthenticationAuditError.invalidIdentifier
    }
    let userUUID = try userID.map { userID in
        guard let value = UUID(uuidString: userID.rawValue) else {
            throw V2PasswordAuthenticationAuditError.invalidIdentifier
        }
        return value
    }
    guard v2PostgresTimestampMicrosecondsCanEncode(occurredAt.microseconds) else {
        throw V2PasswordAuthenticationAuditError.invalidTimestamp
    }
    try await sql.raw("""
        INSERT INTO im_v2.account_password_authentication_audit
            (event_id, outcome, user_id, device_id, occurred_at)
        VALUES
            (\(bind: UUID()), \(bind: outcome.rawValue), \(bind: userUUID),
             \(bind: deviceUUID), \(bind: occurredAt))
        """).run()
}
