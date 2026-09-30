import Foundation

/// Counters for the durable sendOperation path, independent of legacy append batching.
public struct V2SendOperationBatchMetricsSnapshot: Equatable, Sendable {
    public var inFlightBatches = 0
    public var attemptedBatches: UInt64 = 0
    public var submittedCommands: UInt64 = 0
    public var committedBatches: UInt64 = 0
    public var committedCommands: UInt64 = 0
    public var rolledBackBatches: UInt64 = 0
    public var outcomeUnknownBatches: UInt64 = 0
    public var singletonBatches: UInt64 = 0
    public var largestBatch = 0
    public var executionMillisecondsTotal: UInt64 = 0
    public var executionMillisecondsMax: UInt64 = 0
    public init() {}
}

public protocol V2SendOperationBatchMetricsReading: Sendable {
    func sendOperationBatchMetricsSnapshot() -> V2SendOperationBatchMetricsSnapshot
}
