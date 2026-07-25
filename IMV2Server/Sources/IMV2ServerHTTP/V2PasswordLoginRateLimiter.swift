import Fluent
import Foundation
import IMV2Server
import SQLKit

/// Narrow boundary used by the password route.  It keeps rate-limit storage
/// out of HTTP handlers and makes the route testable without a database.
public protocol V2PasswordLoginAttemptLimiting: Sendable {
    /// Returns the number of whole seconds for which the account handle must
    /// remain blocked, or `nil` when an attempt may proceed.
    func blockedRetryAfterSeconds(accountHandle: String) async throws -> Int?
    func recordFailure(accountHandle: String) async throws
    func reset(accountHandle: String) async throws
}

/// PostgreSQL-backed limiter.  Failure accounting is serialized per canonical
/// handle with an advisory transaction lock, so all account-service replicas
/// observe the same failure window and lockout state.
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
        let current = try await databaseNow(on: sql)
        guard let row = try await sql.raw("SELECT blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").first(decoding: BlockedUntilRow.self),
              let blockedUntil = row.blockedUntil
        else { return nil }
        guard blockedUntil > current else { return nil }
        return max(1, Int(ceil(blockedUntil.timeIntervalSince(current))))
    }

    public func recordFailure(accountHandle: String) async throws {
        let handle = try canonicalAccountHandle(accountHandle)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            let lockKey = "v2-password-login-rate:" + handle
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            let current = try await databaseNow(on: sql)
            let existing = try await sql.raw("SELECT window_started_at, failure_count, blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle) FOR UPDATE").first(decoding: AttemptRow.self)

            if let existing, let blockedUntil = existing.blockedUntil, blockedUntil > current {
                return
            }

            let isCurrentWindow = existing.map { current.timeIntervalSince($0.windowStartedAt) < policy.window } ?? false
            let nextFailureCount = isCurrentWindow ? (existing!.failureCount + 1) : 1
            let windowStartedAt = isCurrentWindow ? existing!.windowStartedAt : current
            let blockedUntil = nextFailureCount >= policy.maximumFailures ? current.addingTimeInterval(policy.lockout) : nil

            if existing == nil {
                try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits (account_handle, window_started_at, failure_count, blocked_until, updated_at) VALUES (\(bind: handle), \(bind: windowStartedAt), \(bind: nextFailureCount), \(bind: blockedUntil), \(bind: current))").run()
            } else {
                try await sql.raw("UPDATE im_v2.account_password_login_rate_limits SET window_started_at = \(bind: windowStartedAt), failure_count = \(bind: nextFailureCount), blocked_until = \(bind: blockedUntil), updated_at = \(bind: current) WHERE account_handle = \(bind: handle)").run()
            }
        }
    }

    public func reset(accountHandle: String) async throws {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else {
            throw V2PasswordLoginRateLimitError.unavailable
        }
        try await sql.raw("DELETE FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").run()
    }
}

private struct TimestampRow: Decodable { let current: Date }
private struct BlockedUntilRow: Decodable {
    let blockedUntil: Date?
    enum CodingKeys: String, CodingKey { case blockedUntil = "blocked_until" }
}
private struct AttemptRow: Decodable {
    let windowStartedAt: Date
    let failureCount: Int
    let blockedUntil: Date?
    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case failureCount = "failure_count"
        case blockedUntil = "blocked_until"
    }
}

private func databaseNow(on sql: any SQLDatabase) async throws -> Date {
    guard let row = try await sql.raw("SELECT CURRENT_TIMESTAMP AS current").first(decoding: TimestampRow.self) else {
        throw V2PasswordLoginRateLimitError.unavailable
    }
    return row.current
}
