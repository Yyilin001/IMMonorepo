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

/// Process-local pressure controller for fan-out delivery claim lanes.
///
/// Delivery is durable and may use spare database capacity aggressively, but
/// it must yield as soon as foreground work queues. The controller therefore
/// keeps a conservative foreground-safe level, scales up one lane at a time
/// only after consecutive saturated passes, and sheds back to the floor in a
/// single observation. It never changes the configured deployment ceiling.
public struct V2AdaptiveFanoutDeliveryConcurrency: Equatable, Sendable {
    public let configuredMaximum: Int
    public let foregroundSafeMaximum: Int
    public let saturatedPassesBeforeScaleUp: Int

    public private(set) var activeConcurrency: Int
    private var consecutiveSaturatedPasses = 0

    public init(
        configuredMaximum: Int,
        foregroundSafeMaximum: Int = 4,
        saturatedPassesBeforeScaleUp: Int = 3
    ) {
        precondition(configuredMaximum > 0)
        precondition(foregroundSafeMaximum > 0)
        precondition(saturatedPassesBeforeScaleUp > 0)
        self.configuredMaximum = configuredMaximum
        self.foregroundSafeMaximum = min(configuredMaximum, foregroundSafeMaximum)
        self.saturatedPassesBeforeScaleUp = saturatedPassesBeforeScaleUp
        activeConcurrency = min(configuredMaximum, foregroundSafeMaximum)
    }

    /// Idle polling is always a one-lane probe. Foreground pressure is sampled
    /// immediately before every pass so queued commands do not wait for a busy
    /// delivery pass to finish before the controller sheds background work.
    public mutating func concurrencyForPass(
        isIdle: Bool,
        foregroundQueued: Int
    ) -> Int {
        precondition(foregroundQueued >= 0)
        if foregroundQueued > 0 {
            activeConcurrency = foregroundSafeMaximum
            consecutiveSaturatedPasses = 0
        }
        return isIdle ? 1 : activeConcurrency
    }

    /// A pass is saturated only when every selected lane filled its bounded
    /// co-located commit transaction. This avoids scaling on sparse or retry
    /// work. Scale-up is deliberately gradual; foreground pressure or an error
    /// immediately cancels the accumulated evidence.
    public mutating func observePass(
        selectedConcurrency: Int,
        claimedCount: Int,
        perLaneSaturationCount: Int,
        foregroundQueued: Int,
        failed: Bool = false
    ) {
        precondition(selectedConcurrency > 0)
        precondition(claimedCount >= 0)
        precondition(perLaneSaturationCount > 0)
        precondition(foregroundQueued >= 0)

        guard !failed, foregroundQueued == 0 else {
            activeConcurrency = foregroundSafeMaximum
            consecutiveSaturatedPasses = 0
            return
        }
        guard selectedConcurrency == activeConcurrency,
              activeConcurrency < configuredMaximum,
              claimedCount >= selectedConcurrency * perLaneSaturationCount
        else {
            consecutiveSaturatedPasses = 0
            return
        }
        consecutiveSaturatedPasses += 1
        guard consecutiveSaturatedPasses >= saturatedPassesBeforeScaleUp else { return }
        activeConcurrency += 1
        consecutiveSaturatedPasses = 0
    }
}
