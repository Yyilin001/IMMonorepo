/// The load client does not materialize message projections. Retain sequence
/// witnesses only after validating a complete online body; H alone is never
/// evidence of application. The real client retains the corresponding bodies.
public struct V2LoadRoomLiveSequences: Sendable {
    private var pending: Set<UInt64> = []
    private let maximumPending: Int
    public var pendingCount: Int { pending.count }
    public init(maximumPending: Int = 128) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
    }
    public mutating func receive(_ sequence: UInt64, after cursor: UInt64) -> UInt64 {
        if cursor < .max, sequence == cursor + 1 { return sequence }
        if sequence > cursor, pending.count < maximumPending { pending.insert(sequence) }
        // Overflow drops only acceleration; the announced H still requires recovery.
        return cursor
    }
    public mutating func applied(through cursor: UInt64) -> (cursor: UInt64, count: Int) {
        pending = pending.filter { $0 > cursor }
        var result = cursor, count = 0
        while result < .max, pending.remove(result + 1) != nil { result += 1; count += 1 }
        return (result, count)
    }
}
