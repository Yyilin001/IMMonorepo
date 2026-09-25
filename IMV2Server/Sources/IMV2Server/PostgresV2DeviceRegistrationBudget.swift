import Foundation
import SQLKit

/// 仅负责设备注册预算的持久化。
///
/// 调用方需持有账号状态锁，并与新设备写入成功同处一个事务；
/// 本组件既不读取也不签发凭据。
struct PostgresV2DeviceRegistrationBudget: Sendable {
    /// 本次部署使用的注册预算策略。
    let policy: V2DeviceRegistrationPolicy

    /// 查询账号当前是否已被注册窗口限流。
    ///
    /// - Parameters:
    ///   - sql: 与成功写入同一事务的数据库连接。
    ///   - userID: 目标账号。
    ///   - now: 本次判定时刻。
    /// - Returns: 需要等待的重试秒数；未达上限或窗口已过期时返回 `nil`。
    /// - Throws: 窗口起点无法编码或重试秒数不可表示时抛出
    ///   ``V2DeviceCredentialServiceError/unavailable``。
    func retryAfter(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws -> Int? {
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: policy.window) else {
            throw V2DeviceCredentialServiceError.unavailable
        }
        guard let row = try await sql.raw("SELECT window_started_at, successful_registrations FROM im_v2.device_registration_rate_limits WHERE user_id = \(bind: userID) AND window_started_at > \(bind: cutoff) FOR UPDATE")
            .first(decoding: DeviceRegistrationRateLimitRow.self)
        else { return nil }
        guard row.successfulRegistrations >= policy.maximumNewDevicesPerWindow
        else { return nil }
        guard let retryAfter = v2RateLimitRetryAfterSeconds(
            windowStartedAt: row.windowStartedAt, now: now, window: policy.window
        ) else { throw V2DeviceCredentialServiceError.unavailable }
        return retryAfter
    }

    /// 记录一次成功的新设备注册。
    ///
    /// 窗口起点按同一完整窗口判断：落在窗口内累加计数，否则重置为新窗口。
    /// 直接使用完整时间戳写入，避免截断导致精度丢失或越过 PostgreSQL 上界。
    ///
    /// - Parameters:
    ///   - sql: 与成功写入同一事务的数据库连接。
    ///   - userID: 目标账号。
    ///   - now: 本次写入时刻。
    /// - Throws: 窗口起点无法编码时抛出
    ///   ``V2DeviceCredentialServiceError/unavailable``。
    func recordSuccess(
        _ sql: any SQLDatabase,
        userID: UUID,
        now: Date
    ) async throws {
        guard let cutoff = v2PostgresPastTimestamp(now: now, interval: policy.window) else {
            throw V2DeviceCredentialServiceError.unavailable
        }
        // 使用与 retryAfter 相同的完整时间窗口。若在存储的起点上
        // 加入截断后的间隔，既会丢失小数秒，也可能越过 PostgreSQL 时间戳上界。
        try await sql.raw("""
            INSERT INTO im_v2.device_registration_rate_limits
                (user_id, window_started_at, successful_registrations, updated_at)
            VALUES (\(bind: userID), \(bind: now), 1, \(bind: now))
            ON CONFLICT (user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at <= \(bind: cutoff)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.device_registration_rate_limits.window_started_at
                END,
                successful_registrations = CASE
                    WHEN im_v2.device_registration_rate_limits.window_started_at <= \(bind: cutoff)
                    THEN 1
                    ELSE im_v2.device_registration_rate_limits.successful_registrations + 1
                END,
                updated_at = GREATEST(im_v2.device_registration_rate_limits.updated_at, EXCLUDED.updated_at)
            """).run()
    }
}

private struct DeviceRegistrationRateLimitRow: Decodable {
    let windowStartedAt: V2PostgresTimestamp
    let successfulRegistrations: Int
    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case successfulRegistrations = "successful_registrations"
    }
}
