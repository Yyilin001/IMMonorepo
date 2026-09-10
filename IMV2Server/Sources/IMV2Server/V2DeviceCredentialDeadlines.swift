import Foundation

/// 由响应构造与持久化共用的同一组已校验生效期限。
///
/// 访问与刷新寿命都会被会话到期时间截断，校验针对截断后的生效值，
/// 而不是未被使用的原始时长之和。
struct V2DeviceCredentialDeadlines: Sendable {
    /// 访问令牌生效到期时刻。
    let accessExpiresAt: Date
    /// 刷新令牌生效到期时刻。
    let refreshExpiresAt: Date
    /// 凭据重放窗口到期时刻。
    let replayExpiresAt: Date

    /// 以签发时刻、会话到期时刻与各项寿命计算生效期限。
    ///
    /// - Parameters:
    ///   - issuedAt: 本次凭据签发时刻。
    ///   - sessionExpiresAt: 会话到期时刻，需晚于 `issuedAt`。
    ///   - accessLifetime: 访问令牌寿命秒数，需为正的有限值。
    ///   - refreshLifetime: 刷新令牌寿命秒数，需为正的有限值。
    ///   - replayWindow: 重放窗口秒数，需能编码为带时区的未来时间戳。
    /// - Throws: 寿命非正或非有限、会话边界逆序、截断后的期限不晚于签发时刻、
    ///   重放窗口无法编码时抛出 ``V2DeviceCredentialServiceError/unavailable``。
    init(issuedAt: Date, sessionExpiresAt: Date, accessLifetime: TimeInterval,
         refreshLifetime: TimeInterval, replayWindow: TimeInterval) throws {
        guard accessLifetime.isFinite, accessLifetime > 0,
              refreshLifetime.isFinite, refreshLifetime > 0,
              v2PostgresTimestampPrecedes(issuedAt, sessionExpiresAt),
              let replayExpiry = v2PostgresFutureTimestamp(now: issuedAt, interval: replayWindow)
        else { throw V2DeviceCredentialServiceError.unavailable }
        let accessExpiry = min(issuedAt.addingTimeInterval(accessLifetime), sessionExpiresAt)
        let refreshExpiry = min(issuedAt.addingTimeInterval(refreshLifetime), sessionExpiresAt)
        guard v2PostgresTimestampPrecedes(issuedAt, accessExpiry),
              v2PostgresTimestampPrecedes(issuedAt, refreshExpiry)
        else { throw V2DeviceCredentialServiceError.unavailable }
        accessExpiresAt = accessExpiry
        refreshExpiresAt = refreshExpiry
        replayExpiresAt = replayExpiry
    }
}
