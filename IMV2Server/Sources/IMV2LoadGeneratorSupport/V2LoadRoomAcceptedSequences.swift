/// Device-local knowledge from validated successful send receipts. This never
/// supplies missing peer events or announces an authoritative recovery head.
public struct V2LoadRoomAcceptedSequences: Sendable {
    public struct Progress: Sendable {
        public let cursor: UInt64
        public let appliedAcceptedCount: Int
    }
    public enum Failure: Error { case capacityExceeded }
    private let maximumPending: Int
    private var pending: Set<UInt64> = []
    public var pendingCount: Int { pending.count }
    public init(maximumPending: Int = 128) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
    }
    public mutating func accepted(_ sequence: UInt64, after cursor: UInt64) throws -> Progress {
        if cursor < .max, sequence == cursor + 1 {
            let result = applied(through: sequence)
            return .init(cursor: result.cursor, appliedAcceptedCount: result.appliedAcceptedCount + 1)
        }
        if sequence > cursor, !pending.contains(sequence) {
            guard pending.count < maximumPending else { throw Failure.capacityExceeded }
            pending.insert(sequence)
        }
        return applied(through: cursor)
    }
    public mutating func applied(through cursor: UInt64) -> Progress {
        pending = pending.filter { $0 > cursor }
        var current = cursor, count = 0
        while current < .max, pending.remove(current + 1) != nil {
            current += 1; count += 1
        }
        return .init(cursor: current, appliedAcceptedCount: count)
    }
}
