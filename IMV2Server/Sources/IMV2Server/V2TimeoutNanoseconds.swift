import Foundation

/// Round positive timeouts up to the scheduler's nanosecond tick so converting
/// units cannot shorten a wait or turn a positive timeout into immediate expiry.
func v2TimeoutNanoseconds(_ seconds: TimeInterval) -> Int64? {
    guard seconds.isFinite, seconds > 0,
          let value = Int64(exactly: (seconds * 1_000_000_000).rounded(.up)),
          value > 0 else { return nil }
    return value
}
