import Foundation

public enum V2WorkerCadenceDecision: Equatable, Sendable {
    /// Start the next bounded database pass without a timer.
    case continueImmediately
    /// Cooperatively hand execution to competing work before continuing.
    case yield
    /// No durable work was found; sleep using the bounded idle backoff.
    case sleep(Duration)
}

/// Separates a backlog drain from idle polling. Busy database transactions are
/// already bounded and release their connection after every pass, so inserting
/// the idle poll interval between them only creates artificial throughput
/// limits. Pass and wall-time budgets still force a cooperative yield so a hot
/// projector cannot monopolize one executor turn indefinitely.
public struct V2BoundedBusyDrainCadence: Equatable, Sendable {
    public let maximumConsecutiveBusyPasses: Int
    public let maximumConsecutiveBusyDuration: Duration

    private var idleCadence: V2AdaptiveWorkerCadence
    private var consecutiveBusyPasses = 0
    private var consecutiveBusyDuration: Duration = .zero

    public init(
        minimumIdleIntervalMilliseconds: Int,
        maximumIdleIntervalMilliseconds: Int = 2_000,
        maximumConsecutiveBusyPasses: Int,
        maximumConsecutiveBusyDurationMilliseconds: Int
    ) {
        precondition(maximumConsecutiveBusyPasses > 0)
        precondition(maximumConsecutiveBusyDurationMilliseconds > 0)
        idleCadence = .init(
            minimumIntervalMilliseconds: minimumIdleIntervalMilliseconds,
            maximumIdleIntervalMilliseconds: maximumIdleIntervalMilliseconds
        )
        self.maximumConsecutiveBusyPasses = maximumConsecutiveBusyPasses
        maximumConsecutiveBusyDuration = .milliseconds(
            maximumConsecutiveBusyDurationMilliseconds
        )
    }

    public mutating func decisionAfterPass(
        didWork: Bool,
        passDuration: Duration
    ) -> V2WorkerCadenceDecision {
        precondition(passDuration >= .zero)
        guard didWork else {
            resetBusyWindow()
            return .sleep(idleCadence.delayAfterPass(didWork: false))
        }

        // Reset an idle backoff immediately, but do not use its nonzero busy
        // delay: a busy pass is followed by another bounded claim.
        _ = idleCadence.delayAfterPass(didWork: true)
        if consecutiveBusyPasses < Int.max {
            consecutiveBusyPasses += 1
        }
        consecutiveBusyDuration += passDuration
        guard consecutiveBusyPasses >= maximumConsecutiveBusyPasses ||
                consecutiveBusyDuration >= maximumConsecutiveBusyDuration
        else {
            return .continueImmediately
        }
        resetBusyWindow()
        return .yield
    }

    private mutating func resetBusyWindow() {
        consecutiveBusyPasses = 0
        consecutiveBusyDuration = .zero
    }
}
