import Foundation

/// Pure scheduling policy for non-realtime maintenance work. Keeping this
/// independent of the application loop makes its cadence testable without
/// binding listeners or opening a database connection.
public struct V2MaintenanceCadence: Equatable, Sendable {
    private let interval: TimeInterval

    public init(intervalMilliseconds: Int) throws {
        guard intervalMilliseconds > 0 else { throw V2MaintenanceCadenceError.invalidInterval }
        interval = TimeInterval(intervalMilliseconds) / 1_000
    }

    /// A missing deadline means a newly started worker must perform one pass
    /// immediately; later passes are scheduled from the time that pass began.
    public func isDue(now: Date, nextScheduledAt: Date?) -> Bool {
        guard let nextScheduledAt else { return true }
        return now >= nextScheduledAt
    }

    public func nextScheduledAt(after startedAt: Date) -> Date {
        startedAt.addingTimeInterval(interval)
    }
}

public enum V2MaintenanceCadenceError: Error, Equatable, Sendable {
    case invalidInterval
}
