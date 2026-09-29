import Foundation

/// 将正超时秒数向上取整到调度器可用的纳秒刻度，避免单位换算缩短等待时间或把正超时变成立即到期。
///
/// - Parameter seconds: 以秒表示的超时长度。
/// - Returns: 大于零的纳秒值；`seconds` 非有限、非正，或换算结果超出 `Int64` 表示范围时返回 `nil`。
package func v2TimeoutNanoseconds(_ seconds: TimeInterval) -> Int64? {
    guard seconds.isFinite, seconds > 0,
          let value = Int64(exactly: (seconds * 1_000_000_000).rounded(.up)),
          value > 0 else { return nil }
    return value
}
