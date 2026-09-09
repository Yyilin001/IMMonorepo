import Foundation

/// A bounded whole-second retry hint for the same Date-to-PostgreSQL cutoff
/// used by durable account budgets. Native timestamps must not round-trip
/// through Date or epoch seconds before comparing this boundary.
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
