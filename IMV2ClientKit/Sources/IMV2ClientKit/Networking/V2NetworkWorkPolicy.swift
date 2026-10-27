import Foundation

/// Domain steps may carry scheduling metadata to their leaf transport without
/// taking a parent permit. This scope grants no credential or durable claim.
public enum V2NetworkWorkScope {
    @TaskLocal public static var context: V2NetworkWorkContext?
}

/// Pure retry decisions. Callers persist attempt counts and budgets; this type never retries I/O.
public struct V2NetworkWorkPolicy: Sendable {
    public let maximumAttempts: Int
    public let totalBudget: TimeInterval
    public let transmissionBudget: TimeInterval
    public init(maximumAttempts: Int, totalBudget: TimeInterval, transmissionBudget: TimeInterval) {
        precondition(maximumAttempts > 0 && totalBudget > 0 && transmissionBudget > 0)
        self.maximumAttempts = maximumAttempts; self.totalBudget = totalBudget; self.transmissionBudget = transmissionBudget
    }
    public static let interactiveRead = Self(maximumAttempts: 2, totalBudget: 10, transmissionBudget: 10)
    public static let commandRecovery = Self(maximumAttempts: 5, totalBudget: 60, transmissionBudget: 15)
    /// Returns nil when exhausted or when the server cooldown cannot fit the remaining budget.
    public func nextAttempt(now: Date, startedAt: Date, attemptsCompleted: Int,
                            randomUnit: Double, serverRetryNotBefore: Date? = nil) -> Date? {
        guard attemptsCompleted < maximumAttempts else { return nil }
        let exponent = min(max(0, attemptsCompleted - 1), 16)
        let ceiling = min(30, 0.5 * pow(2, Double(exponent)))
        let deadline = startedAt.addingTimeInterval(totalBudget)
        let base = max(now, serverRetryNotBefore ?? now)
        let remaining = deadline.timeIntervalSince(base)
        guard remaining > 0 else { return nil }
        // Jitter starts after the server's minimum cooldown. Taking max after
        // sampling collapses clients onto the same cooldown boundary.
        let window = min(ceiling, remaining)
        let next = base.addingTimeInterval(window * min(1, max(0, randomUnit)))
        return next < deadline ? next : nil
    }
    public static func acceptedResultPollDelay(attempt: Int, serverDelay: TimeInterval? = nil) -> TimeInterval {
        let defaults: [TimeInterval] = [2, 5, 10, 30]
        return max(defaults[min(3, max(0, attempt))], serverDelay ?? 0)
    }

    /// Image processing normally completes in seconds. Keep a short bounded
    /// initial observation window, then back off; server cooldown always wins.
    public static func resourceProcessingPollDelay(attempt: Int, serverDelay: TimeInterval? = nil) -> TimeInterval {
        let delays: [TimeInterval] = [0.5, 0.5, 0.5, 0.5, 0.75, 1, 2, 5, 10, 30]
        return max(delays[min(delays.count - 1, max(0, attempt))], serverDelay ?? 0)
    }
}

/// Failed-history retry quota; initial interactive attempts do not consume this bucket.
public struct V2NetworkRetryTokenBucket: Sendable {
    private var tokens: Int = 5
    private var lastRefill: TimeInterval
    public init(now: TimeInterval) { lastRefill = now }
    private mutating func refill(now: TimeInterval) {
        if now >= lastRefill + 2 {
            let intervals = floor((now - lastRefill) / 2)
            tokens = min(5, tokens + Int(min(5, intervals))); lastRefill += intervals * 2
        }
    }
    public mutating func nextAvailableAt(now: TimeInterval) -> TimeInterval {
        refill(now: now)
        return tokens > 0 ? now : lastRefill + 2
    }
    public mutating func consume(now: TimeInterval) -> Bool {
        refill(now: now)
        guard tokens > 0 else { return false }
        tokens -= 1; return true
    }
}
