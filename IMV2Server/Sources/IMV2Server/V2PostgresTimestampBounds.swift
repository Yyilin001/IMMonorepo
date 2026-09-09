import Foundation

/// 验证日期能否转换为驱动使用的 PostgreSQL 有限时间戳。
///
/// - Parameter date: 即将绑定到数据库参数的实际日期。
/// - Returns: 相对 2000-01-01 的微秒偏移向零舍入后可由 `Int64` 表示，且处于数据库有限范围时返回 `true`。
///
/// 检查最终日期而非仅检查持续时长，避免日期加法溢出或驱动非抛出式整数转换失败。
/// 不接受数据库无穷时间哨兵，也不要求日期必须在 Unix 纪元之后。
func v2PostgresTimestampCanEncode(_ date: Date) -> Bool {
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    let microseconds = (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
    guard let offset = Int64(exactly: microseconds) else { return false }
    return v2PostgresTimestampMicrosecondsCanEncode(offset)
}

/// 检查相对 PostgreSQL 纪元的微秒偏移是否落入有限时间戳范围。
///
/// - Parameter offset: 相对 2000-01-01 的有符号微秒偏移。
/// - Returns: 位于下界（含）与上界（不含）之间时返回 `true`。
///
/// 仅能放入 `Int64` 不足以证明数据库接受该时间；本方法进一步检查数据库的有限值边界。
func v2PostgresTimestampMicrosecondsCanEncode(_ offset: Int64) -> Bool {
    // PostgreSQL datatype/timestamp.h: IS_VALID_TIMESTAMP uses these finite
    // bounds. An offset fitting Int64 can still be rejected by PostgreSQL,
    // notably before 4713 BC or near the upper endpoint.
    return offset >= -211_813_488_000_000_000 && offset < 9_223_371_331_200_000_000
}

/// 按数据库实际微秒精度验证两个日期严格有序。
///
/// - Parameters:
///   - earlier: 期望更早的日期。
///   - later: 期望更晚的日期。
/// - Returns: 两者均可编码，且向零舍入后的微秒偏移严格递增时返回 `true`。
///
/// 原始 `Date` 值不同但编码后相等时返回 `false`，适用于持久化期限的严格顺序约束。
func v2PostgresTimestampPrecedes(_ earlier: Date, _ later: Date) -> Bool {
    guard v2PostgresTimestampCanEncode(earlier), v2PostgresTimestampCanEncode(later) else { return false }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    return (earlier.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
        < (later.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
}

/// 计算可持久化且编码后仍严格晚于基准的截止时间。
///
/// - Parameters:
///   - now: 必须可编码的基准日期。
///   - interval: 正且有限的持续秒数。
/// - Returns: 加法结果可编码且微秒偏移严格增加时返回该日期，否则返回 `nil`。
///
/// 同时检查两端范围和加法后的有效精度，避免较小间隔在大日期值上丢失后形成无效期限。
func v2PostgresFutureTimestamp(now: Date, interval: TimeInterval) -> Date? {
    guard interval.isFinite, interval > 0, v2PostgresTimestampCanEncode(now) else { return nil }
    let expiry = now.addingTimeInterval(interval)
    guard v2PostgresTimestampCanEncode(expiry) else { return nil }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard (expiry.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
            > (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else { return nil }
    return expiry
}

/// 计算可持久化且编码后严格早于基准的保留截止时间。
///
/// - Parameters:
///   - now: 必须可编码的当前日期。
///   - interval: 正且有限的保留时长秒数。
/// - Returns: 减法结果可编码且微秒偏移严格减少时返回该日期，否则返回 `nil`。
///
/// 拒绝因精度丢失而等于当前时间的结果，避免清理逻辑把新写入记录当作已超出保留期。
func v2PostgresPastTimestamp(now: Date, interval: TimeInterval) -> Date? {
    guard interval.isFinite, interval > 0, v2PostgresTimestampCanEncode(now) else { return nil }
    let cutoff = now.addingTimeInterval(-interval)
    guard v2PostgresTimestampCanEncode(cutoff) else { return nil }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard (cutoff.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
            < (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else { return nil }
    return cutoff
}

/// 检查限流持续时间是否为正且可用有符号微秒偏移表示。
///
/// - Parameter duration: 待验证的秒数。
/// - Returns: 秒数大于零，且微秒值向上舍入后可由 `Int64` 表示时返回 `true`；非有限值也会被拒绝。
///
/// 此检查约束时长及其向上取整的重试秒数，不保证任意基准日期加上该时长后仍可编码；绝对期限需另行验证。
func v2RateLimitDurationIsRepresentable(_ duration: TimeInterval) -> Bool {
    duration > 0 && Int64(exactly: (duration * 1_000_000).rounded(.up)) != nil
}
