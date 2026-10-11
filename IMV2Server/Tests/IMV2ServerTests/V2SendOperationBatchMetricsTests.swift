import Testing
import IMV2ServerContracts
@testable import IMV2ServerApplication

@Suite("Durable send operation metrics")
struct V2SendOperationBatchMetricsTests {
    @Test("SQL continuation segments retain independent pending ownership across physical owners")
    func sqlContinuationTransitionsAggregate() {
        let first = V2SendOperationBatchMetrics(), second = V2SendOperationBatchMetrics()
        let aggregate = V2AggregatedSendOperationBatchMetrics(owners: [first, second])
        #expect(Set(aggregate.sendOperationBatchMetricsSnapshot().sqlContinuations.keys)
            == Set(V2RoomSQLContinuationSource.allCases))
        first.recordSQLResultSettled(source: .lifecycleLeases)
        first.recordSQLResultSettled(source: .lifecycleLeases)
        first.recordSQLTaskResumed(source: .lifecycleLeases, duration: .milliseconds(2))
        second.recordSQLResultSettled(source: .lifecycleLeases)
        second.recordSQLTaskResumed(source: .lifecycleLeases, duration: .milliseconds(3))
        let pending = aggregate.sendOperationBatchMetricsSnapshot().sqlContinuations[.lifecycleLeases]!
        #expect(pending.settledNotResumed == 1 && pending.resumedNotDispatched == 2)
        #expect(pending.settledToResumedCount == 2 && pending.resumedToDispatchCount == 0)
        first.recordSQLNextDispatch(source: .lifecycleLeases, duration: .milliseconds(5))
        second.recordSQLNoNextDispatch(source: .lifecycleLeases)
        let ended = aggregate.sendOperationBatchMetricsSnapshot().sqlContinuations[.lifecycleLeases]!
        #expect(ended.settledNotResumed == 1 && ended.resumedNotDispatched == 0)
        #expect(ended.settledToResumedCount == 2 && ended.settledToResumedTotalMilliseconds == 5)
        #expect(ended.settledToResumedMaxMilliseconds == 3)
        #expect(ended.resumedToDispatchCount == 1 && ended.resumedToDispatchTotalMilliseconds == 5)
        #expect(ended.resumedToDispatchMaxMilliseconds == 5 && ended.noNextDispatch == 1)
        first.recordSQLTaskResumed(source: .lifecycleLeases, duration: .milliseconds(-1))
        first.recordSQLNextDispatch(source: .lifecycleLeases, duration: .milliseconds(-2))
        let complete = aggregate.sendOperationBatchMetricsSnapshot().sqlContinuations[.lifecycleLeases]!
        #expect(complete.settledNotResumed == 0 && complete.resumedNotDispatched == 0)
        #expect(complete.settledToResumedCount == 3 && complete.resumedToDispatchCount == 2)
        #expect(complete.settledToResumedTotalMilliseconds == 5 && complete.resumedToDispatchTotalMilliseconds == 5)
        for source in V2RoomSQLContinuationSource.allCases where source != .lifecycleLeases {
            #expect(aggregate.sendOperationBatchMetricsSnapshot().sqlContinuations[source] == V2RoomSQLContinuationSnapshot())
        }
    }

    @Test("stage completion is concurrent-safe, monotonic and retains actual in-flight ownership")
    func stageCompletionIsOnce() async {
        let first = V2SendOperationBatchMetrics(), second = V2SendOperationBatchMetrics()
        let aggregate = V2AggregatedSendOperationBatchMetrics(owners: [first, second])
        let timer = first.startStage(.ownerBody)
        let remaining = second.startStage(.ownerBody)
        #expect(aggregate.sendOperationBatchMetricsSnapshot().stages.count == V2SendOperationStage.allCases.count)
        #expect(aggregate.sendOperationBatchMetricsSnapshot().stages[.ownerBody]?.inFlight == 2)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { timer.finish() } }
        }
        let partial = aggregate.sendOperationBatchMetricsSnapshot().stages[.ownerBody]!
        #expect(partial.inFlight == 1 && partial.count == 1)
        #expect(partial.totalMilliseconds >= 0 && partial.maxMilliseconds == partial.totalMilliseconds)
        remaining.finish()
        let complete = aggregate.sendOperationBatchMetricsSnapshot().stages[.ownerBody]!
        #expect(complete.inFlight == 0 && complete.count == 2)
        #expect(complete.totalMilliseconds >= partial.totalMilliseconds)
        #expect(complete.maxMilliseconds >= partial.maxMilliseconds)
        for stage in V2SendOperationStage.allCases where stage != .ownerBody {
            #expect(aggregate.sendOperationBatchMetricsSnapshot().stages[stage] == V2SendOperationStageMetricsSnapshot())
        }
    }

    @Test("physical owners aggregate actual durable turn sizes and completion outcomes")
    func durableTurnMetrics() {
        let first = V2SendOperationBatchMetrics(), second = V2SendOperationBatchMetrics()
        first.recordOwnerAdmissionHandoff(path: .singleSuccess,
            resultReadyToValidated: .milliseconds(2), validatedToCommitDispatch: .milliseconds(5))
        second.recordOwnerAdmissionHandoff(path: .singleSuccess,
            resultReadyToValidated: .milliseconds(3), validatedToCommitDispatch: .milliseconds(4))
        first.recordOwnerAdmissionHandoff(path: .singleFallback,
            resultReadyToValidated: .milliseconds(-1), validatedToCommitDispatch: .milliseconds(-2))
        first.recordOwnerCohortStarted(handleCount: 2, commandCount: 4)
        second.recordOwnerCohortStarted(handleCount: 3, commandCount: 3)
        first.recordOwnerCohortCommitted(acceptedCommandCount: 3, replayedCommandCount: 1)
        second.recordOwnerCohortCommitted(acceptedCommandCount: 0, replayedCommandCount: 3)
        first.recordOwnerScalarFallback(handleCount: 1, commandCount: 2, reason: .optimizationNotApplicable)
        second.recordOwnerScalarFallback(handleCount: 1, commandCount: 3, reason: .optimizationNotApplicable)
        second.recordOwnerCohortIsolation()
        first.begin(commandCount: 3)
        second.begin(commandCount: 1)
        let aggregate = V2AggregatedSendOperationBatchMetrics(owners: [first, second])
        #expect(aggregate.sendOperationBatchMetricsSnapshot().inFlightBatches == 2)
        first.finish(commandCount: 3, outcome: .committed, duration: .milliseconds(12))
        second.finish(commandCount: 1, outcome: .outcomeUnknown, duration: .milliseconds(5))
        first.begin(commandCount: 2)
        first.finish(commandCount: 2, outcome: .rolledBack, duration: .milliseconds(2))
        let result = aggregate.sendOperationBatchMetricsSnapshot()
        #expect(result.ownerAdmissionHandoffs.count == V2SendOperationAdmissionPath.allCases.count)
        let handoff = result.ownerAdmissionHandoffs[.singleSuccess]!
        #expect(handoff.count == 2)
        #expect(handoff.resultReadyToValidatedMillisecondsTotal == 5)
        #expect(handoff.resultReadyToValidatedMillisecondsMax == 3)
        #expect(handoff.validatedToCommitDispatchMillisecondsTotal == 9)
        #expect(handoff.validatedToCommitDispatchMillisecondsMax == 5)
        let clamped = result.ownerAdmissionHandoffs[.singleFallback]!
        #expect(clamped.count == 1 && clamped.resultReadyToValidatedMillisecondsTotal == 0)
        #expect(clamped.resultReadyToValidatedMillisecondsMax == 0)
        #expect(clamped.validatedToCommitDispatchMillisecondsTotal == 0 && clamped.validatedToCommitDispatchMillisecondsMax == 0)
        #expect(result.ownerAdmissionHandoffs[.multiGroup] == V2SendOperationAdmissionHandoffSnapshot())
        #expect(result.inFlightBatches == 0)
        #expect(result.attemptedBatches == 3 && result.submittedCommands == 6)
        #expect(result.committedBatches == 1 && result.committedCommands == 3)
        #expect(result.rolledBackBatches == 1 && result.outcomeUnknownBatches == 1)
        #expect(result.singletonBatches == 1 && result.largestBatch == 3)
        #expect(result.executionMillisecondsTotal == 19 && result.executionMillisecondsMax == 12)
        #expect(result.ownerCohortAttempts == 2 && result.ownerCohortHandles == 5 && result.ownerCohortCommands == 7)
        #expect(result.ownerCohortCommits == 2 && result.ownerCohortAcceptedCommands == 3 && result.ownerCohortReplayedCommands == 4)
        #expect(result.ownerCohortIsolations == 1)
        #expect(result.ownerScalarFallbacks.count == V2SendOperationOwnerScalarFallbackReason.allCases.count)
        #expect(result.ownerScalarFallbacks[.optimizationNotApplicable]?.handles == 2)
        #expect(result.ownerScalarFallbacks[.optimizationNotApplicable]?.commands == 5)
        for reason in V2SendOperationOwnerScalarFallbackReason.allCases where reason != .optimizationNotApplicable {
            #expect(result.ownerScalarFallbacks[reason] == V2SendOperationOwnerScalarFallbackSnapshot())
        }
    }
}
