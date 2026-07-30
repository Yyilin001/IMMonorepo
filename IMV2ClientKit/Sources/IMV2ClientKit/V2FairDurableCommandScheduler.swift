import Foundation

/// A bounded weighted round-robin scheduler for independent durable command
/// lanes. Each lane gets one quantum per round, so a retrying or heavily
/// backlogged low-priority lane cannot indefinitely delay withdrawal,
/// moderation, membership or receipt actions.
public struct V2FairDurableCommandScheduler: Sendable {
    public struct Lane: Sendable {
        public let flushOne: @Sendable () async throws -> Bool

        /// Return `true` when one durable item made progress (including a
        /// persisted retry/rejection), or `false` when the lane is idle.
        public init(flushOne: @escaping @Sendable () async throws -> Bool) {
            self.flushOne = flushOne
        }
    }

    private let lanes: [Lane]

    public init(lanes: [Lane]) {
        precondition(!lanes.isEmpty)
        self.lanes = lanes
    }

    @discardableResult
    public func flush(maximumWorkItems: Int) async throws -> Int {
        precondition(maximumWorkItems > 0)
        var remaining = maximumWorkItems
        var completed = 0
        while remaining > 0 {
            var madeProgress = false
            for lane in lanes where remaining > 0 {
                try Task.checkCancellation()
                guard try await lane.flushOne() else { continue }
                madeProgress = true
                completed += 1
                remaining -= 1
            }
            guard madeProgress else { break }
        }
        return completed
    }
}
