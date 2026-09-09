import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Narrow capability used by the password transport adapter. Failure
/// accounting and audit persistence remain one server-side transaction.
public protocol V2PasswordLoginAttemptLimiting: Sendable {
    func blockedRetryAfterSeconds(accountHandle: String) async throws -> Int?
    func recordRejectedAttempt(accountHandle: String, userID: UserID?, deviceID: DeviceID) async throws
    func recordSuccessfulAttempt(accountHandle: String, userID: UserID, deviceID: DeviceID) async throws
}

/// PostgreSQL-backed limiter. Failure accounting is serialized per canonical
/// handle so all account-service replicas observe the same window and lockout.
public struct V2PostgresPasswordLoginAttemptLimiter: V2PasswordLoginAttemptLimiting, Sendable {
    private let database: any Database
    private let policy: V2PasswordLoginRateLimitPolicy

    public init(database: any Database, policy: V2PasswordLoginRateLimitPolicy) {
        self.database = database
        self.policy = policy
    }

    public func blockedRetryAfterSeconds(accountHandle: String) async throws -> Int? {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else {
            throw V2PasswordLoginRateLimitError.unavailable
        }
        let current: V2PostgresTimestamp = try await databaseNow(on: sql)
        guard let row = try await sql.raw("SELECT blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").first(decoding: BlockedUntilRow.self),
              let blockedUntil = row.blockedUntil
        else { return nil }
        guard blockedUntil.microseconds > current.microseconds else { return nil }
        // Subtract whole seconds and remainders separately: the complete
        // PostgreSQL timestamp span can overflow an Int64 microsecond delta.
        let scale: Int64 = 1_000_000
        let seconds = blockedUntil.microseconds / scale - current.microseconds / scale
        let remainder = blockedUntil.microseconds % scale - current.microseconds % scale
        let roundedRemainder = remainder / scale + (remainder % scale > 0 ? 1 : 0)
        guard let retryAfter = Int(exactly: seconds + roundedRemainder), retryAfter > 0 else {
            throw V2PasswordLoginRateLimitError.unavailable
        }
        return retryAfter
    }

    public func recordRejectedAttempt(
        accountHandle: String,
        userID: UserID?,
        deviceID: DeviceID
    ) async throws {
        let handle = try canonicalAccountHandle(accountHandle)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            try await v2LockPasswordAttempts(sql, handle: handle)
            let observed: V2PostgresTimestamp = try await databaseNow(on: sql)
            let current = observed.date
            let existing = try await sql.raw("SELECT window_started_at, failure_count, blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle) FOR UPDATE").first(decoding: AttemptRow.self)

            if let existing, let blockedUntil = existing.blockedUntil,
               blockedUntil.microseconds > observed.microseconds {
                return
            }

            guard let windowMicroseconds = Int64(exactly: (policy.window * 1_000_000).rounded(.up)) else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            let isCurrentWindow = existing.map { existing in
                // Preserve an existing window during a backward clock
                // correction. A positive full-range delta may overflow.
                if observed.microseconds < existing.windowStartedAt.microseconds { return true }
                let (elapsed, overflow) = observed.microseconds.subtractingReportingOverflow(existing.windowStartedAt.microseconds)
                return !overflow && elapsed < windowMicroseconds
            } ?? false
            // This limiter count is a threshold, not a revision or operation
            // identity. Keep a saturated denial at the SQL integer ceiling;
            // an expired lockout in the same window must not overflow the
            // column and roll back the new lockout and its audit.
            let nextFailureCount = isCurrentWindow
                ? min(existing!.failureCount, Int(Int32.max) - 1) + 1 : 1
            let windowStartedAt = isCurrentWindow ? existing!.windowStartedAt : observed
            let blockedUntil = nextFailureCount >= policy.maximumFailures
                ? current.addingTimeInterval(policy.lockout)
                : nil
            guard v2PostgresTimestampCanEncode(current),
                  // A positive duration can disappear in Date or microsecond
                  // encoding. Never persist an already-elapsed lockout.
                  blockedUntil.map({ expiry in
                      guard v2PostgresTimestampPrecedes(current, expiry),
                            let encoded = try? V2PostgresTimestamp(date: expiry) else { return false }
                      return encoded.microseconds > observed.microseconds
                  }) ?? true
            else { throw V2PasswordLoginRateLimitError.unavailable }

            if existing == nil {
                try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits (account_handle, window_started_at, failure_count, blocked_until, updated_at) VALUES (\(bind: handle), \(bind: windowStartedAt), \(bind: nextFailureCount), \(bind: blockedUntil), \(bind: observed))").run()
            } else {
                try await sql.raw("UPDATE im_v2.account_password_login_rate_limits SET window_started_at = \(bind: windowStartedAt), failure_count = \(bind: nextFailureCount), blocked_until = \(bind: blockedUntil), updated_at = \(bind: observed) WHERE account_handle = \(bind: handle)").run()
            }
            try await recordPasswordAuthenticationAudit(
                outcome: .assertionRejected,
                userID: userID,
                deviceID: deviceID,
                occurredAt: observed,
                on: sql
            )
        }
    }

    public func recordSuccessfulAttempt(
        accountHandle: String,
        userID: UserID,
        deviceID: DeviceID
    ) async throws {
        let handle = try canonicalAccountHandle(accountHandle)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            try await v2LockPasswordAttempts(sql, handle: handle)
            let current: V2PostgresTimestamp = try await databaseNow(on: sql)
            try await sql.raw("DELETE FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").run()
            try await recordPasswordAuthenticationAudit(
                outcome: .assertionSucceeded,
                userID: userID,
                deviceID: deviceID,
                occurredAt: current,
                on: sql
            )
        }
    }
}

private struct TimestampRow<Value: Decodable>: Decodable { let current: Value }

private struct BlockedUntilRow: Decodable {
    let blockedUntil: V2PostgresTimestamp?
    enum CodingKeys: String, CodingKey { case blockedUntil = "blocked_until" }
}

private struct AttemptRow: Decodable {
    let windowStartedAt: V2PostgresTimestamp
    let failureCount: Int
    let blockedUntil: V2PostgresTimestamp?

    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case failureCount = "failure_count"
        case blockedUntil = "blocked_until"
    }
}

private func databaseNow<Value: Decodable>(on sql: any SQLDatabase) async throws -> Value {
    // CURRENT_TIMESTAMP is fixed at transaction start, before an advisory
    // lock may have waited. Account for the attempt using time observed now.
    guard let row = try await sql.raw("SELECT clock_timestamp() AS current").first(decoding: TimestampRow<Value>.self) else {
        throw V2PasswordLoginRateLimitError.unavailable
    }
    return row.current
}

func v2LockPasswordAttempts(_ sql: any SQLDatabase, handle: String) async throws {
    let lockKey = "v2-password-login-rate:" + handle
    try await sql.raw(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
    ).run()
}
