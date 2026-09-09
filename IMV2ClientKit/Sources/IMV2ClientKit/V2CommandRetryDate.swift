import Foundation

/// A persisted retry must advance wall time; otherwise the durable scheduler
/// can repeatedly rediscover the same command without sleeping.
func v2CommandRetryDate(now: Date, delay: TimeInterval) throws -> Date {
    let deadline = now.addingTimeInterval(delay)
    guard now.timeIntervalSince1970.isFinite, delay.isFinite, delay > 0,
          deadline.timeIntervalSince1970.isFinite, deadline > now else {
        throw V2CommandRetrySchedulerError.invalidDate
    }
    return deadline
}
