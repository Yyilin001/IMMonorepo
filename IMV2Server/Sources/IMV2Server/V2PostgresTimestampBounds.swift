import Foundation

/// postgres-nio encodes Date as an Int64 microsecond offset from 2000-01-01
/// using a nonthrowing conversion. Validate the actual value before handing
/// it to that driver; merely checking a duration does not bound date addition.
func v2PostgresTimestampCanEncode(_ date: Date) -> Bool {
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    let microseconds = (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
    guard let offset = Int64(exactly: microseconds) else { return false }
    return v2PostgresTimestampMicrosecondsCanEncode(offset)
}

func v2PostgresTimestampMicrosecondsCanEncode(_ offset: Int64) -> Bool {
    // PostgreSQL datatype/timestamp.h: IS_VALID_TIMESTAMP uses these finite
    // bounds. An offset fitting Int64 can still be rejected by PostgreSQL,
    // notably before 4713 BC or near the upper endpoint.
    return offset >= -211_813_488_000_000_000 && offset < 9_223_371_331_200_000_000
}

/// Absolute deadlines must remain strictly ordered after the driver's
/// microsecond conversion, as required by persisted grant constraints.
func v2PostgresTimestampPrecedes(_ earlier: Date, _ later: Date) -> Bool {
    guard v2PostgresTimestampCanEncode(earlier), v2PostgresTimestampCanEncode(later) else { return false }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    return (earlier.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
        < (later.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
}

/// Validate both ends of a lifetime and require a strictly future deadline
/// after the driver's microsecond conversion, including Date precision loss.
func v2PostgresFutureTimestamp(now: Date, interval: TimeInterval) -> Date? {
    guard interval.isFinite, interval > 0, v2PostgresTimestampCanEncode(now) else { return nil }
    let expiry = now.addingTimeInterval(interval)
    guard v2PostgresTimestampCanEncode(expiry) else { return nil }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard (expiry.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
            > (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else { return nil }
    return expiry
}

/// A retention cutoff must remain strictly before now after encoding; an
/// interval that disappears must not make freshly written rows reclaimable.
func v2PostgresPastTimestamp(now: Date, interval: TimeInterval) -> Date? {
    guard interval.isFinite, interval > 0, v2PostgresTimestampCanEncode(now) else { return nil }
    let cutoff = now.addingTimeInterval(-interval)
    guard v2PostgresTimestampCanEncode(cutoff) else { return nil }
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard (cutoff.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
            < (now.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero) else { return nil }
    return cutoff
}

/// A rate-limit duration must be positive and finite, and fit the timestamp
/// offset domain. This also bounds its rounded-up HTTP Retry-After seconds.
func v2RateLimitDurationIsRepresentable(_ duration: TimeInterval) -> Bool {
    duration > 0 && Int64(exactly: (duration * 1_000_000).rounded(.up)) != nil
}
