import Foundation

/// Value-type scheduler for durable workers that are woken by both hints and
/// bounded polling. Busy passes retain the configured low-latency cadence;
/// consecutive empty/error passes back off exponentially to protect the
/// database when a replica is idle. The maximum remains finite because broker
/// notifications are deliberately only hints, never a correctness boundary.
public struct V2AdaptiveWorkerCadence: Equatable, Sendable {
    public let minimumIntervalMilliseconds: Int
    public let maximumIdleIntervalMilliseconds: Int

    private var consecutiveIdlePasses = 0

    public init(
        minimumIntervalMilliseconds: Int,
        maximumIdleIntervalMilliseconds: Int = 2_000
    ) {
        precondition(minimumIntervalMilliseconds > 0)
        precondition(maximumIdleIntervalMilliseconds >= minimumIntervalMilliseconds)
        self.minimumIntervalMilliseconds = minimumIntervalMilliseconds
        self.maximumIdleIntervalMilliseconds = maximumIdleIntervalMilliseconds
    }

    /// An empty worker only needs one claim lane on its next pass. As soon as
    /// any durable work is observed, the caller restores its configured
    /// concurrency for the following pass.
    public var isIdle: Bool { consecutiveIdlePasses > 0 }

    /// Bounds the first claim after an idle period to a single durable item.
    ///
    /// Merely reducing concurrency is insufficient for workers whose one
    /// claim lane can acquire a large batch and then process its members
    /// sequentially. Such a probe cannot report that work exists until the
    /// complete batch drains, so the runtime may remain at idle concurrency
    /// for seconds under a sudden burst. A one-item probe preserves cheap
    /// idle polling and lets the very next pass restore the configured batch
    /// size and concurrency.
    public func claimLimit(configuredLimit: Int) -> Int {
        precondition(configuredLimit > 0)
        return isIdle ? 1 : configuredLimit
    }

    public mutating func delayAfterPass(didWork: Bool) -> Duration {
        if didWork {
            consecutiveIdlePasses = 0
            return .milliseconds(minimumIntervalMilliseconds)
        }

        consecutiveIdlePasses = min(consecutiveIdlePasses + 1, 30)
        let exponent = min(consecutiveIdlePasses - 1, 20)
        let multiplier = 1 << exponent
        let (candidate, overflowed) = minimumIntervalMilliseconds.multipliedReportingOverflow(by: multiplier)
        return .milliseconds(min(overflowed ? maximumIdleIntervalMilliseconds : candidate, maximumIdleIntervalMilliseconds))
    }
}
