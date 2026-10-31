import Foundation

/// One visible load gets at most four delayed byte retries before waiting for
/// normal display reauthorization. A retry never changes the display deadline.
struct V2AvatarRetrySchedule {
    private var attempts = 0

    mutating func next(retryAt: ContinuousClock.Instant?, deadline: ContinuousClock.Instant,
                       now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        guard let retryAt, attempts < 4, deadline > now else { return nil }
        attempts += 1
        return min(deadline, max(retryAt, now + .seconds(1 << attempts)))
    }
}
