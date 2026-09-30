import Foundation
import IMV2ServerContracts
import Synchronization

/// One recorder per physical owner; fixed counters contain no room or user labels.
public final class V2SendOperationBatchMetrics: V2SendOperationBatchMetricsReading, Sendable {
    public enum Outcome: Sendable { case committed, rolledBack, outcomeUnknown }
    private let state = Mutex(V2SendOperationBatchMetricsSnapshot())
    public init() {}

    public func begin(commandCount: Int) {
        precondition(commandCount > 0)
        state.withLock {
            $0.inFlightBatches += 1
            $0.attemptedBatches = Self.add($0.attemptedBatches, 1)
            $0.submittedCommands = Self.add($0.submittedCommands, UInt64(commandCount))
            if commandCount == 1 { $0.singletonBatches = Self.add($0.singletonBatches, 1) }
            $0.largestBatch = max($0.largestBatch, commandCount)
        }
    }

    public func finish(commandCount: Int, outcome: Outcome, duration: Duration) {
        let components = duration.components
        let elapsed = max(0, Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
        let milliseconds = elapsed < Double(UInt64.max) ? UInt64(elapsed) : UInt64.max
        state.withLock {
            precondition($0.inFlightBatches > 0)
            $0.inFlightBatches -= 1
            switch outcome {
            case .committed:
                $0.committedBatches = Self.add($0.committedBatches, 1)
                $0.committedCommands = Self.add($0.committedCommands, UInt64(commandCount))
            case .rolledBack: $0.rolledBackBatches = Self.add($0.rolledBackBatches, 1)
            case .outcomeUnknown: $0.outcomeUnknownBatches = Self.add($0.outcomeUnknownBatches, 1)
            }
            $0.executionMillisecondsTotal = Self.add($0.executionMillisecondsTotal, milliseconds)
            $0.executionMillisecondsMax = max($0.executionMillisecondsMax, milliseconds)
        }
    }

    public func sendOperationBatchMetricsSnapshot() -> V2SendOperationBatchMetricsSnapshot {
        state.withLock { $0 }
    }

    fileprivate static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? .max : value.partialValue
    }
}

public struct V2AggregatedSendOperationBatchMetrics: V2SendOperationBatchMetricsReading {
    private let owners: [any V2SendOperationBatchMetricsReading]
    public init(owners: [any V2SendOperationBatchMetricsReading]) { self.owners = owners }
    public func sendOperationBatchMetricsSnapshot() -> V2SendOperationBatchMetricsSnapshot {
        var result = V2SendOperationBatchMetricsSnapshot()
        for owner in owners {
            let item = owner.sendOperationBatchMetricsSnapshot()
            result.inFlightBatches += item.inFlightBatches
            result.attemptedBatches = V2SendOperationBatchMetrics.add(result.attemptedBatches, item.attemptedBatches)
            result.submittedCommands = V2SendOperationBatchMetrics.add(result.submittedCommands, item.submittedCommands)
            result.committedBatches = V2SendOperationBatchMetrics.add(result.committedBatches, item.committedBatches)
            result.committedCommands = V2SendOperationBatchMetrics.add(result.committedCommands, item.committedCommands)
            result.rolledBackBatches = V2SendOperationBatchMetrics.add(result.rolledBackBatches, item.rolledBackBatches)
            result.outcomeUnknownBatches = V2SendOperationBatchMetrics.add(result.outcomeUnknownBatches, item.outcomeUnknownBatches)
            result.singletonBatches = V2SendOperationBatchMetrics.add(result.singletonBatches, item.singletonBatches)
            result.largestBatch = max(result.largestBatch, item.largestBatch)
            result.executionMillisecondsTotal = V2SendOperationBatchMetrics.add(result.executionMillisecondsTotal, item.executionMillisecondsTotal)
            result.executionMillisecondsMax = max(result.executionMillisecondsMax, item.executionMillisecondsMax)
        }
        return result
    }
}
