import Foundation

/// 为持久化账号预算计算同一 Date 到 PostgreSQL 截止点上的有界整秒重试提示。
///
/// 比较边界前不允许把原生的 `V2PersistenceTimestamp` 经过 `Date` 或 epoch 秒往返，
/// 因此先把窗口参数编码为 PostgreSQL 时间戳，再对整秒偏移做二分查找。
///
/// - Parameters:
///   - windowStartedAt: 已持久化的窗口开始时刻。
///   - now: 本次观测的服务端时刻。
///   - window: 窗口长度，需能表示为整秒并编码为 PostgreSQL 时间戳。
/// - Returns: 介于 1 与窗口整秒上界之间的重试秒数；`window` 不可表示、`now` 或截止点
///   无法编码时返回 `nil`。窗口已经过期时返回 1；时钟回拨使存储窗口落在未来时，
///   返回上界值且不改变已持久化的窗口。
package func v2RateLimitRetryAfterSeconds(
    windowStartedAt: V2PersistenceTimestamp,
    now: Date,
    window: TimeInterval
) -> Int? {
    guard v2RateLimitDurationIsRepresentable(window),
          let ceiling = Int(exactly: window.rounded(.up)),
          let cutoff = v2PostgresPastTimestamp(now: now, interval: window),
          let encodedCutoff = try? V2PersistenceTimestamp(date: cutoff),
          let encodedNow = try? V2PersistenceTimestamp(date: now) else { return nil }
    guard windowStartedAt.microseconds > encodedCutoff.microseconds else { return 1 }
    // 时钟校正若使已存窗口落在未来，仍保留既有的有界提示；
    // 不能改动持久化窗口。
    guard windowStartedAt.microseconds <= encodedNow.microseconds else { return ceiling }

    var lower = 1
    var upper = ceiling
    while lower < upper {
        let middle = lower + (upper - lower) / 2
        let futureCutoff = now.addingTimeInterval(Double(middle)).addingTimeInterval(-window)
        // 截止点从已验证的初始值单调推进。
        // 后续截止点若无法编码，就已超出 PostgreSQL 的上界。
        if let encoded = try? V2PersistenceTimestamp(date: futureCutoff),
           encoded.microseconds < windowStartedAt.microseconds {
            lower = middle + 1
        } else {
            upper = middle
        }
    }
    // 即使时钟校正或其表示方式让窗口超出有界重试提示，
    // 返回值也不超过既定上限。
    return lower
}
