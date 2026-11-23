/// Explicit proof requirements for a benchmark's selected workload.
public enum V2LoadCompletionPolicy {
    public static func scopePassed(ready: Bool, requiresAppliedCursor: Bool,
                                   appliedCursor: UInt64, highWatermark: UInt64) -> Bool {
        ready && (!requiresAppliedCursor || appliedCursor >= highWatermark)
    }
    public static func receiverComplete(sent: Int, acknowledged: Int, observed: Int) -> Bool {
        sent == acknowledged && acknowledged == observed
    }
}

/// Completion evidence for an unsuccessful load-generator operation.
public enum V2LoadMessageFailure {
    case unknown(String)
    case failed(String)

    public static func retryBudgetExhausted(resubmitting: Bool) -> Self {
        .unknown(resubmitting ? "DEFERRED_RETRY_EXHAUSTED" : "UNRESOLVED")
    }

    public var auditOutcome: String {
        switch self {
        case .unknown: "unknown"
        case .failed: "failed"
        }
    }

    public var code: String {
        switch self {
        case .unknown(let reason): "TCP_OUTCOME_UNKNOWN_" + reason
        case .failed(let code): code
        }
    }
}
