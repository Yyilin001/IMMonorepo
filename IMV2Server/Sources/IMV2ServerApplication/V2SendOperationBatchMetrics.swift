import Foundation
import IMV2ServerContracts
import Synchronization
import IMV2ActorContracts

/// Explicit completion belongs to the actual operation, not its caller's lifetime.
/// The timer retains the recorder and completes synchronously exactly once.
public final class V2SendOperationStageTimer: Sendable {
    private let completed = Mutex(false)
    private let startedAt = ContinuousClock.now
    private let completion: @Sendable (Duration) -> Void

    fileprivate init(completion: @escaping @Sendable (Duration) -> Void) { self.completion = completion }

    public func finish() {
        completed.withLock { finished in
            guard !finished else { return }
            finished = true
            completion(startedAt.duration(to: .now))
        }
    }
}

/// One recorder per physical owner; fixed counters contain no room or user labels.
public final class V2SendOperationBatchMetrics: V2SendOperationBatchMetricsReading, Sendable {
    public enum Outcome: Sendable { case committed, rolledBack, outcomeUnknown }
    private let state = Mutex(V2SendOperationBatchMetricsSnapshot())
    public init() {}

    public func recordPolicyMemoryEvent(_ event: V2PolicyMemoryEvent) {
        state.withLock { $0.policyMemoryEvents[event] = Self.add($0.policyMemoryEvents[event, default: 0], 1) }
    }

    /// A completed diagnostic interval; does not acquire or release resources.
    package func recordCompletedStage(_ stage: V2SendOperationStage, duration: Duration) {
        let elapsed = Self.milliseconds(duration)
        state.withLock {
            var item = $0.stages[stage, default: .init()]
            item.count = Self.add(item.count, 1)
            item.totalMilliseconds += elapsed
            item.maxMilliseconds = max(item.maxMilliseconds, elapsed)
            $0.stages[stage] = item
        }
    }

    public func startStage(_ stage: V2SendOperationStage) -> V2SendOperationStageTimer {
        state.withLock { $0.stages[stage, default: .init()].inFlight += 1 }
        let trace = V2SendPathTrace.current, startedAt = ContinuousClock.now
        return V2SendOperationStageTimer { [self] duration in
            trace?.record(stage.rawValue, from: startedAt)
            let parts = duration.components
            let elapsed = max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
            state.withLock {
                var item = $0.stages[stage, default: .init()]
                precondition(item.inFlight > 0)
                item.inFlight -= 1
                item.count = Self.add(item.count, 1)
                item.totalMilliseconds += elapsed
                item.maxMilliseconds = max(item.maxMilliseconds, elapsed)
                $0.stages[stage] = item
            }
        }
    }

    /// Call only after successful quota validation and beginCommit, immediately
    /// before COMMIT dispatch. Negative monotonic-clock durations clamp to zero.
    public func recordOwnerAdmissionHandoff(path: V2SendOperationAdmissionPath,
        resultReadyToValidated: Duration, validatedToCommitDispatch: Duration) {
        let ready = Self.milliseconds(resultReadyToValidated)
        let dispatch = Self.milliseconds(validatedToCommitDispatch)
        state.withLock {
            var item = $0.ownerAdmissionHandoffs[path, default: .init()]
            item.count = Self.add(item.count, 1)
            item.resultReadyToValidatedMillisecondsTotal += ready
            item.resultReadyToValidatedMillisecondsMax = max(item.resultReadyToValidatedMillisecondsMax, ready)
            item.validatedToCommitDispatchMillisecondsTotal += dispatch
            item.validatedToCommitDispatchMillisecondsMax = max(item.validatedToCommitDispatchMillisecondsMax, dispatch)
            $0.ownerAdmissionHandoffs[path] = item
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }

    /// Called on the actual SQL future's event loop, including failed futures.
    public func recordSQLResultSettled(source: V2RoomSQLContinuationSource) {
        state.withLock { $0.sqlContinuations[source, default: .init()].settledNotResumed += 1 }
    }

    /// Moves one actually settled result to its resumed Swift continuation.
    public func recordSQLTaskResumed(source: V2RoomSQLContinuationSource, duration: Duration) {
        let elapsed = Self.milliseconds(duration)
        state.withLock {
            var item = $0.sqlContinuations[source, default: .init()]
            precondition(item.settledNotResumed > 0)
            item.settledNotResumed -= 1
            item.resumedNotDispatched += 1
            item.settledToResumedCount = Self.add(item.settledToResumedCount, 1)
            item.settledToResumedTotalMilliseconds += elapsed
            item.settledToResumedMaxMilliseconds = max(item.settledToResumedMaxMilliseconds, elapsed)
            $0.sqlContinuations[source] = item
        }
    }

    /// Records an explicitly observed adjacent API dispatch, not its completion.
    public func recordSQLNextDispatch(source: V2RoomSQLContinuationSource, duration: Duration) {
        let elapsed = Self.milliseconds(duration)
        state.withLock {
            var item = $0.sqlContinuations[source, default: .init()]
            precondition(item.resumedNotDispatched > 0)
            item.resumedNotDispatched -= 1
            item.resumedToDispatchCount = Self.add(item.resumedToDispatchCount, 1)
            item.resumedToDispatchTotalMilliseconds += elapsed
            item.resumedToDispatchMaxMilliseconds = max(item.resumedToDispatchMaxMilliseconds, elapsed)
            $0.sqlContinuations[source] = item
        }
    }

    /// Ends a sequence without recording its successor dispatch; unobserved
    /// SQL or transaction finalization may continue. No duration is invented.
    public func recordSQLNoNextDispatch(source: V2RoomSQLContinuationSource) {
        state.withLock {
            var item = $0.sqlContinuations[source, default: .init()]
            precondition(item.resumedNotDispatched > 0)
            item.resumedNotDispatched -= 1
            item.noNextDispatch = Self.add(item.noNextDispatch, 1)
            $0.sqlContinuations[source] = item
        }
    }

    /// Record immediately before the actual setwise transaction attempt.
    public func recordOwnerCohortStarted(handleCount: Int, commandCount: Int) {
        precondition(handleCount > 0 && commandCount >= handleCount)
        state.withLock {
            $0.ownerCohortAttempts = Self.add($0.ownerCohortAttempts, 1)
            $0.ownerCohortHandles = Self.add($0.ownerCohortHandles, UInt64(handleCount))
            $0.ownerCohortCommands = Self.add($0.ownerCohortCommands, UInt64(commandCount))
        }
    }

    /// Only a confirmed COMMIT records its new acceptances and permanent replays.
    public func recordOwnerCohortCommitted(acceptedCommandCount: Int, replayedCommandCount: Int) {
        precondition(acceptedCommandCount >= 0 && replayedCommandCount >= 0)
        state.withLock {
            $0.ownerCohortCommits = Self.add($0.ownerCohortCommits, 1)
            $0.ownerCohortAcceptedCommands = Self.add($0.ownerCohortAcceptedCommands, UInt64(acceptedCommandCount))
            $0.ownerCohortReplayedCommands = Self.add($0.ownerCohortReplayedCommands, UInt64(replayedCommandCount))
        }
    }

    /// Each original scalar execution is counted once, irrespective of prior isolation depth.
    public func recordOwnerScalarFallback(handleCount: Int, commandCount: Int,
        reason: V2SendOperationOwnerScalarFallbackReason) {
        precondition(handleCount > 0 && commandCount >= handleCount)
        state.withLock {
            var item = $0.ownerScalarFallbacks[reason, default: .init()]
            item.handles = Self.add(item.handles, UInt64(handleCount))
            item.commands = Self.add(item.commands, UInt64(commandCount))
            $0.ownerScalarFallbacks[reason] = item
        }
    }

    /// A proven rollback enters binary isolation; this is not a fallback-command count.
    public func recordOwnerCohortIsolation() {
        state.withLock { $0.ownerCohortIsolations = Self.add($0.ownerCohortIsolations, 1) }
    }

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
            for event in V2PolicyMemoryEvent.allCases {
                result.policyMemoryEvents[event] = V2SendOperationBatchMetrics.add(
                    result.policyMemoryEvents[event, default: 0], item.policyMemoryEvents[event, default: 0])
            }
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
            result.ownerCohortAttempts = V2SendOperationBatchMetrics.add(result.ownerCohortAttempts, item.ownerCohortAttempts)
            result.ownerCohortHandles = V2SendOperationBatchMetrics.add(result.ownerCohortHandles, item.ownerCohortHandles)
            result.ownerCohortCommands = V2SendOperationBatchMetrics.add(result.ownerCohortCommands, item.ownerCohortCommands)
            result.ownerCohortCommits = V2SendOperationBatchMetrics.add(result.ownerCohortCommits, item.ownerCohortCommits)
            result.ownerCohortAcceptedCommands = V2SendOperationBatchMetrics.add(result.ownerCohortAcceptedCommands, item.ownerCohortAcceptedCommands)
            result.ownerCohortReplayedCommands = V2SendOperationBatchMetrics.add(result.ownerCohortReplayedCommands, item.ownerCohortReplayedCommands)
            result.ownerCohortIsolations = V2SendOperationBatchMetrics.add(result.ownerCohortIsolations, item.ownerCohortIsolations)
            for reason in V2SendOperationOwnerScalarFallbackReason.allCases {
                let measurement = item.ownerScalarFallbacks[reason, default: .init()]
                var combined = result.ownerScalarFallbacks[reason, default: .init()]
                combined.handles = V2SendOperationBatchMetrics.add(combined.handles, measurement.handles)
                combined.commands = V2SendOperationBatchMetrics.add(combined.commands, measurement.commands)
                result.ownerScalarFallbacks[reason] = combined
            }
            for path in V2SendOperationAdmissionPath.allCases {
                let measurement = item.ownerAdmissionHandoffs[path, default: .init()]
                var combined = result.ownerAdmissionHandoffs[path, default: .init()]
                combined.count = V2SendOperationBatchMetrics.add(combined.count, measurement.count)
                combined.resultReadyToValidatedMillisecondsTotal += measurement.resultReadyToValidatedMillisecondsTotal
                combined.resultReadyToValidatedMillisecondsMax = max(combined.resultReadyToValidatedMillisecondsMax,
                    measurement.resultReadyToValidatedMillisecondsMax)
                combined.validatedToCommitDispatchMillisecondsTotal += measurement.validatedToCommitDispatchMillisecondsTotal
                combined.validatedToCommitDispatchMillisecondsMax = max(combined.validatedToCommitDispatchMillisecondsMax,
                    measurement.validatedToCommitDispatchMillisecondsMax)
                result.ownerAdmissionHandoffs[path] = combined
            }
            for source in V2RoomSQLContinuationSource.allCases {
                let measurement = item.sqlContinuations[source, default: .init()]
                var combined = result.sqlContinuations[source, default: .init()]
                combined.settledNotResumed += measurement.settledNotResumed
                combined.resumedNotDispatched += measurement.resumedNotDispatched
                combined.settledToResumedCount = V2SendOperationBatchMetrics.add(combined.settledToResumedCount,
                    measurement.settledToResumedCount)
                combined.settledToResumedTotalMilliseconds += measurement.settledToResumedTotalMilliseconds
                combined.settledToResumedMaxMilliseconds = max(combined.settledToResumedMaxMilliseconds,
                    measurement.settledToResumedMaxMilliseconds)
                combined.resumedToDispatchCount = V2SendOperationBatchMetrics.add(combined.resumedToDispatchCount,
                    measurement.resumedToDispatchCount)
                combined.resumedToDispatchTotalMilliseconds += measurement.resumedToDispatchTotalMilliseconds
                combined.resumedToDispatchMaxMilliseconds = max(combined.resumedToDispatchMaxMilliseconds,
                    measurement.resumedToDispatchMaxMilliseconds)
                combined.noNextDispatch = V2SendOperationBatchMetrics.add(combined.noNextDispatch, measurement.noNextDispatch)
                result.sqlContinuations[source] = combined
            }
            for stage in V2SendOperationStage.allCases {
                let measurement = item.stages[stage, default: .init()]
                var combined = result.stages[stage, default: .init()]
                combined.inFlight += measurement.inFlight
                combined.count = V2SendOperationBatchMetrics.add(combined.count, measurement.count)
                combined.totalMilliseconds += measurement.totalMilliseconds
                combined.maxMilliseconds = max(combined.maxMilliseconds, measurement.maxMilliseconds)
                result.stages[stage] = combined
            }
        }
        return result
    }
}

/// The composition root supplies each physical owner once, irrespective of
/// logical shard aliases. Gauges are sampled asynchronously from their actors.
public struct V2AggregatedSendOperationOwnerMetrics: V2SendOperationOwnerMetricsReading {
    private let owners: [any V2SendOperationOwnerMetricsReading]
    public init(owners: [any V2SendOperationOwnerMetricsReading]) { self.owners = owners }
    public func sendOperationOwnerMetricsSnapshot() async -> V2SendOperationOwnerMetricsSnapshot {
        var result = V2SendOperationOwnerMetricsSnapshot()
        var stageCounts: [V2SendOperationOwnerBatchStage: Int] = [:]
        var stagesSupported = !owners.isEmpty
        for owner in owners {
            let item = await owner.sendOperationOwnerMetricsSnapshot()
            result.retainedItems += item.retainedItems
            result.retainedBytes += item.retainedBytes
            result.queuedTurns += item.queuedTurns
            result.waitingPolicyTurns += item.waitingPolicyTurns
            result.inFlightBatches += item.inFlightBatches
            if let stages = item.stages {
                for stage in V2SendOperationOwnerBatchStage.allCases {
                    stageCounts[stage, default: 0] += stages[stage, default: 0]
                }
            } else { stagesSupported = false }
            result.batchesStarted = V2SendOperationBatchMetrics.add(result.batchesStarted, item.batchesStarted)
            result.batchesCompleted = V2SendOperationBatchMetrics.add(result.batchesCompleted, item.batchesCompleted)
            result.commandsSubmitted = V2SendOperationBatchMetrics.add(result.commandsSubmitted, item.commandsSubmitted)
            result.largestBatch = max(result.largestBatch, item.largestBatch)
            result.largestRoomCount = max(result.largestRoomCount, item.largestRoomCount)
        }
        result.stages = stagesSupported ? stageCounts : nil
        return result
    }
}
