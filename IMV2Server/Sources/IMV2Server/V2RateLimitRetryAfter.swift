import Foundation

/// 为持久化账号预算计算同一 Date 到 PostgreSQL 截止点上的有界整秒重试提示。
///
/// 比较边界前不允许把原生的 `V2PostgresTimestamp` 经过 `Date` 或 epoch 秒往返，
/// 因此先把窗口参数编码为 PostgreSQL 时间戳，再对整秒偏移做二分查找。
///
/// - Parameters:
///   - windowStartedAt: 已持久化的窗口开始时刻。
///   - now: 本次观测的服务端时刻。
///   - window: 窗口长度，需能表示为整秒并编码为 PostgreSQL 时间戳。
/// - Returns: 介于 1 与窗口整秒上界之间的重试秒数；`window` 不可表示、`now` 或截止点
///   无法编码时返回 `nil`。窗口已经过期时返回 1；时钟回拨使存储窗口落在未来时，
///   返回上界值且不改变已持久化的窗口。
func v2RateLimitRetryAfterSeconds(
    windowStartedAt: V2PostgresTimestamp,
    now: Date,
    window: TimeInterval
) -> Int? {
    guard v2RateLimitDurationIsRepresentable(window),
          let ceiling = Int(exactly: window.rounded(.up)),
          let cutoff = v2PostgresPastTimestamp(now: now, interval: window),
          let encodedCutoff = try? V2PostgresTimestamp(date: cutoff),
          let encodedNow = try? V2PostgresTimestamp(date: now) else { return nil }
    guard windowStartedAt.microseconds > encodedCutoff.microseconds else { return 1 }
    // Retain the existing bounded hint when a clock correction puts the
    // stored window in the future; it must not change the persisted window.
    guard windowStartedAt.microseconds <= encodedNow.microseconds else { return ceiling }

    var lower = 1
    var upper = ceiling
    while lower < upper {
        let middle = lower + (upper - lower) / 2
        let futureCutoff = now.addingTimeInterval(Double(middle)).addingTimeInterval(-window)
        // Cutoffs advance monotonically from the already-valid initial one.
        // A non-encodable later cutoff is beyond PostgreSQL's upper bound.
        if let encoded = try? V2PostgresTimestamp(date: futureCutoff),
           encoded.microseconds < windowStartedAt.microseconds {
            lower = middle + 1
        } else {
            upper = middle
        }
    }
    // At most the established ceiling, even if a clock correction or its
    // representation leaves the window beyond that bounded retry hint.
    return lower
}
