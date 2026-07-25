import Foundation

/// Determines how durable fan-out work reacts to a transient worker failure.
/// Exhaustion pauses the row for an operator replay; it never converts a
/// delivery into a terminal skip or releases source-room admission capacity.
public struct V2DurableRetryPolicy: Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let maximumAttempts: Int
    public let jitterFraction: Double

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        maximumAttempts: Int = 10,
        jitterFraction: Double = 0.2
    ) {
        precondition(initialDelay > 0 && initialDelay.isFinite)
        precondition(maximumDelay >= initialDelay && maximumDelay.isFinite)
        precondition(maximumAttempts > 0)
        precondition((0...1).contains(jitterFraction) && jitterFraction.isFinite)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
        self.jitterFraction = jitterFraction
    }

    public static let standard = Self()

    public func disposition(attempt: Int, claimToken: UUID, now: Date) -> V2DurableRetryDisposition {
        precondition(attempt > 0)
        guard attempt < maximumAttempts else { return .pause }
        let exponent = min(attempt - 1, 30)
        let exponential = initialDelay * Double(1 << exponent)
        let baseDelay = min(maximumDelay, exponential)
        let centeredJitter = (jitterUnit(for: claimToken) * 2) - 1
        let jitteredDelay = baseDelay * (1 + (centeredJitter * jitterFraction))
        return .retry(at: now.addingTimeInterval(min(maximumDelay, max(0.001, jitteredDelay))))
    }

    private func jitterUnit(for token: UUID) -> Double {
        let bytes = token.uuid
        let value = UInt16(bytes.0) << 8 | UInt16(bytes.1)
        return Double(value) / Double(UInt16.max)
    }
}

public enum V2DurableRetryDisposition: Equatable, Sendable {
    case retry(at: Date)
    case pause
}
