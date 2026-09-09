/// Pure scheduling policy for non-realtime maintenance work. Keeping this
/// independent of the application loop makes its cadence testable without
/// binding listeners or opening a database connection.
public struct V2MaintenanceCadence: Equatable, Sendable {
    private let interval: Duration

    public init(intervalMilliseconds: Int) throws {
        guard intervalMilliseconds > 0 else { throw V2MaintenanceCadenceError.invalidInterval }
        interval = .milliseconds(intervalMilliseconds)
    }

    /// A missing deadline means a newly started worker must perform one pass
    /// immediately; later passes are scheduled from the time that pass began.
    /// A monotonic deadline keeps wall-clock corrections from delaying or
    /// accelerating cleanup. Workers still use wall time for persisted expiry.
    public func isDue(now: ContinuousClock.Instant, nextScheduledAt: ContinuousClock.Instant?) -> Bool {
        guard let nextScheduledAt else { return true }
        return now >= nextScheduledAt
    }

    public func nextScheduledAt(after startedAt: ContinuousClock.Instant) -> ContinuousClock.Instant {
        startedAt.advanced(by: interval)
    }
}

public enum V2MaintenanceCadenceError: Error, Equatable, Sendable {
    case invalidInterval
}
