/// Fixed batch-only stages. Caller session waiting and owned local dispatch
/// settlement are distinct; neither proves that a remote independent task ended.
public enum V2RoomTransportRecoveryStage: String, CaseIterable, Sendable {
    case sessionCallerWait = "session_caller_wait"
    case actualDispatch = "actual_dispatch"
}

public struct V2RoomTransportRecoveryStageSnapshot: Equatable, Sendable {
    public let active: Int
    public let started: UInt64
    public let completed: UInt64
    public let totalMilliseconds: Double
    public let maxMilliseconds: Double
    public let oldestMilliseconds: Double
    public let itemsStarted: UInt64

    public init(active: Int = 0, started: UInt64 = 0, completed: UInt64 = 0,
                totalMilliseconds: Double = 0, maxMilliseconds: Double = 0,
                oldestMilliseconds: Double = 0, itemsStarted: UInt64 = 0) {
        self.active = active
        self.started = started
        self.completed = completed
        self.totalMilliseconds = totalMilliseconds
        self.maxMilliseconds = maxMilliseconds
        self.oldestMilliseconds = oldestMilliseconds
        self.itemsStarted = itemsStarted
    }
}
