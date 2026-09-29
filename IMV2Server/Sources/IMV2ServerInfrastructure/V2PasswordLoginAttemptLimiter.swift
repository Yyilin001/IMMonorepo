import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit


/// 基于 PostgreSQL 的登录限流实现。
///
/// 失败计数按规范化账号标识串行化，使全部账号服务副本观察到同一窗口与同一锁定状态。
public struct V2PostgresPasswordLoginAttemptLimiter: V2PasswordLoginAttemptLimiting, Sendable {
    private let database: any Database
    private let policy: V2PasswordLoginRateLimitPolicy

    /// 组合数据库与限流策略。
    ///
    /// - Parameters:
    ///   - database: 存放登录失败窗口的数据库。
    ///   - policy: 部署选定的限流策略。
    public init(database: any Database, policy: V2PasswordLoginRateLimitPolicy) {
        self.database = database
        self.policy = policy
    }

    public func consumeAttempt(accountHandle: String) async throws -> Int? {
        try await accountForAttempt(accountHandle: accountHandle, audit: nil)
    }

    public func auditRejectedAttempt(accountHandle: String, userID: UserID?, deviceID: DeviceID) async throws {
        _ = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else { throw V2PasswordLoginRateLimitError.unavailable }
        let observed: V2PersistenceTimestamp = try await databaseNow(on: sql)
        try await recordPasswordAuthenticationAudit(outcome: .assertionRejected, userID: userID,
            deviceID: deviceID, occurredAt: observed, on: sql)
    }

    /// 查询账号当前剩余锁定时间。
    ///
    /// 秒与微秒余数分开相减后向上取整，避免完整时间戳跨度在 `Int64` 微秒差上溢出。
    ///
    /// - Parameter accountHandle: 账号标识。
    /// - Returns: 大于零的等待秒数；未锁定或锁定已过期时返回 `nil`。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordLoginRateLimitError/invalidPolicy``；连接不支持 SQL、时刻读取失败或
    ///   等待秒数不可表示时抛出 ``V2PasswordLoginRateLimitError/unavailable``。
    public func blockedRetryAfterSeconds(accountHandle: String) async throws -> Int? {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else {
            throw V2PasswordLoginRateLimitError.unavailable
        }
        let current: V2PersistenceTimestamp = try await databaseNow(on: sql)
        guard let row = try await sql.raw("SELECT blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle)").first(decoding: BlockedUntilRow.self),
              let blockedUntil = row.blockedUntil
        else { return nil }
        guard blockedUntil.microseconds > current.microseconds else { return nil }
        // 整秒与余数分开相减：PostgreSQL 的完整时间戳跨度
        // 可能使 Int64 微秒差溢出。
        let scale: Int64 = 1_000_000
        let seconds = blockedUntil.microseconds / scale - current.microseconds / scale
        let remainder = blockedUntil.microseconds % scale - current.microseconds % scale
        let roundedRemainder = remainder / scale + (remainder % scale > 0 ? 1 : 0)
        guard let retryAfter = Int(exactly: seconds + roundedRemainder), retryAfter > 0 else {
            throw V2PasswordLoginRateLimitError.unavailable
        }
        return retryAfter
    }

    /// 在单个事务内累计失败次数并在达到阈值时写入锁定。
    ///
    /// 已处于锁定期的尝试不再重复计数。窗口判断在时钟回拨时保留既有窗口；
    /// 失败次数以 SQL 整数上限饱和，避免同窗口内既有锁定过期时计数溢出并回滚新的锁定与审计。
    /// 锁定到期时刻必须确实晚于观测时刻，否则视为不可用而不落库。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - userID: 账号对应用户；账号不存在时为空。
    ///   - deviceID: 发起尝试的设备。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordLoginRateLimitError/invalidPolicy``；连接、时刻或窗口编码不可用时抛出
    ///   ``V2PasswordLoginRateLimitError/unavailable``。
    public func recordRejectedAttempt(
        accountHandle: String,
        userID: UserID?,
        deviceID: DeviceID
    ) async throws {
        _ = try await accountForAttempt(accountHandle: accountHandle, audit: (userID, deviceID))
    }

    private func accountForAttempt(accountHandle: String, audit: (UserID?, DeviceID)?) async throws -> Int? {
        let handle = try canonicalAccountHandle(accountHandle)
        return try await database.transaction { transaction -> Int? in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            try await v2LockPasswordAttempts(sql, handle: handle)
            let observed: V2PersistenceTimestamp = try await databaseNow(on: sql)
            let current = observed.date
            let existing = try await sql.raw("SELECT window_started_at, failure_count, blocked_until FROM im_v2.account_password_login_rate_limits WHERE account_handle = \(bind: handle) FOR UPDATE").first(decoding: AttemptRow.self)

            if let existing, let blockedUntil = existing.blockedUntil,
               blockedUntil.microseconds > observed.microseconds {
                let scale: Int64 = 1_000_000
                let seconds = blockedUntil.microseconds / scale - observed.microseconds / scale
                let remainder = blockedUntil.microseconds % scale - observed.microseconds % scale
                guard let retry = Int(exactly: seconds + remainder / scale + (remainder % scale > 0 ? 1 : 0)), retry > 0 else {
                    throw V2PasswordLoginRateLimitError.unavailable
                }
                return retry
            }

            guard let windowMicroseconds = Int64(exactly: (policy.window * 1_000_000).rounded(.up)) else {
                throw V2PasswordLoginRateLimitError.unavailable
            }
            let isCurrentWindow = existing.map { existing in
                // 时钟向后校正时保留既有窗口。
                // 跨完整取值范围的正时间差可能溢出。
                if observed.microseconds < existing.windowStartedAt.microseconds { return true }
                let (elapsed, overflow) = observed.microseconds.subtractingReportingOverflow(existing.windowStartedAt.microseconds)
                return !overflow && elapsed < windowMicroseconds
            } ?? false
            // 此限流计数是阈值，不是修订号或操作标识。
            // 拒绝计数在 SQL 整数上界饱和；同一窗口中已过期的锁定
            // 不能使列溢出，进而回滚新的锁定及其审计记录。
            let nextFailureCount = isCurrentWindow
                ? min(existing!.failureCount, Int(Int32.max) - 1) + 1 : 1
            let windowStartedAt = isCurrentWindow ? existing!.windowStartedAt : observed
            let blockedUntil = nextFailureCount >= policy.maximumFailures
                ? current.addingTimeInterval(policy.lockout)
                : nil
            guard v2PostgresTimestampCanEncode(current),
                  // 正时长可能在 Date 或微秒编码时消失。
                  // 绝不持久化已经结束的锁定。
                  blockedUntil.map({ expiry in
                      guard v2PostgresTimestampPrecedes(current, expiry),
                            let encoded = try? V2PersistenceTimestamp(date: expiry) else { return false }
                      return encoded.microseconds > observed.microseconds
                  }) ?? true
            else { throw V2PasswordLoginRateLimitError.unavailable }

            if existing == nil {
                try await sql.raw("INSERT INTO im_v2.account_password_login_rate_limits (account_handle, window_started_at, failure_count, blocked_until, updated_at) VALUES (\(bind: handle), \(bind: windowStartedAt), \(bind: nextFailureCount), \(bind: blockedUntil), \(bind: observed))").run()
            } else {
                try await sql.raw("UPDATE im_v2.account_password_login_rate_limits SET window_started_at = \(bind: windowStartedAt), failure_count = \(bind: nextFailureCount), blocked_until = \(bind: blockedUntil), updated_at = \(bind: observed) WHERE account_handle = \(bind: handle)").run()
            }
            if let audit {
                try await recordPasswordAuthenticationAudit(outcome: .assertionRejected,
                    userID: audit.0, deviceID: audit.1, occurredAt: observed, on: sql)
            }
            return nil
        }
    }

    /// 在单个事务内清空失败窗口并记录成功审计。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - userID: 账号对应用户。
    ///   - deviceID: 发起尝试的设备。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordLoginRateLimitError/invalidPolicy``；其余失败抛出
    ///   ``V2PasswordLoginRateLimitError/unavailable``。
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
            let current: V2PersistenceTimestamp = try await databaseNow(on: sql)
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
    let blockedUntil: V2PersistenceTimestamp?
    enum CodingKeys: String, CodingKey { case blockedUntil = "blocked_until" }
}

private struct AttemptRow: Decodable {
    let windowStartedAt: V2PersistenceTimestamp
    let failureCount: Int
    let blockedUntil: V2PersistenceTimestamp?

    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case failureCount = "failure_count"
        case blockedUntil = "blocked_until"
    }
}

/// 读取数据库当前时刻。
///
/// 使用 `clock_timestamp()` 而非事务起始时间，因为咨询锁可能已等待过一段时间，
/// 计数必须基于本次尝试真正被处理时的时刻。
///
/// - Parameter sql: 当前事务使用的数据库连接。
/// - Returns: 数据库给出的当前时刻。
/// - Throws: 查询无结果时抛出 ``V2PasswordLoginRateLimitError/unavailable``。
private func databaseNow<Value: Decodable>(on sql: any SQLDatabase) async throws -> Value {
    // CURRENT_TIMESTAMP 固定在事务开始时，早于可能发生的咨询锁等待。
    // 须用当前观测时间计算此次尝试。
    guard let row = try await sql.raw("SELECT clock_timestamp() AS current").first(decoding: TimestampRow<Value>.self) else {
        throw V2PasswordLoginRateLimitError.unavailable
    }
    return row.current
}

/// 取得指定账号的登录尝试咨询锁。
///
/// - Parameters:
///   - sql: 当前事务使用的数据库连接。
///   - handle: 已规范化的账号标识。
/// - Throws: 加锁失败时抛出。
func v2LockPasswordAttempts(_ sql: any SQLDatabase, handle: String) async throws {
    let lockKey = "v2-password-login-rate:" + handle
    try await sql.raw(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
    ).run()
}
