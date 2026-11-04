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
