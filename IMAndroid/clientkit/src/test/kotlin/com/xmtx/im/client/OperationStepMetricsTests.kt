package com.xmtx.im.client

import kotlinx.coroutines.*
import java.io.IOException
import kotlin.test.*

class OperationStepMetricsTests {
    private fun sample(observation:OperationStepObservation?=null)=OperationStepMetric(OperationKind.ContactAlias,
        OperationWorkAction.Submit,1,NetworkWorkPriority.Interactive,0,1,OperationStepMetric.Completion.Returned,observation)

    @Test fun `handler return without durable observation remains unknown`() {
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown,sample().certainty)
        for(state in OperationExecutionState.entries) {
            val expected=when(state) {
                OperationExecutionState.Committed,OperationExecutionState.Rejected,OperationExecutionState.Conflicted,OperationExecutionState.Closed->NetworkMetric.Certainty.ResponseReceived
                OperationExecutionState.Prepared,OperationExecutionState.CancelledLocally,OperationExecutionState.ExpiredUnsubmitted->NetworkMetric.Certainty.NotStarted
                else->NetworkMetric.Certainty.OutcomeUnknown
            }
            assertEquals(expected,sample(OperationStepObservation(state,OperationSchedulingState.NeedsAttention)).certainty)
        }
    }

    @Test fun `window is bounded immutable concurrent and rejects late records`()=runBlocking {
        val diagnostics=NetworkDiagnostics();diagnostics.record(sample());val old=diagnostics.snapshot()
        coroutineScope {repeat(4) {launch(Dispatchers.Default) {repeat(100) {diagnostics.record(sample())}}}}
        assertEquals(401,diagnostics.snapshot().operationRecorded);assertEquals(401,diagnostics.snapshot().recorded)
        assertEquals(128,diagnostics.snapshot().operations.size);assertEquals(1,old.operations.size)
        diagnostics.close();diagnostics.record(sample());assertEquals(401,diagnostics.snapshot().operationRecorded)
        assertTrue(diagnostics.snapshot().operations.isEmpty());assertEquals(1,old.operations.size)
    }

    @Test fun `candidate and handler timing excludes the later durable observation`()=runBlocking {
        val diagnostics=NetworkDiagnostics();var time=10L
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            val result=measureOperationStep(OperationKind.ProfileUpdate,OperationWorkAction.Reconcile,2,true,3,
                observe={time=100;OperationStepObservation(OperationExecutionState.AwaitingConfirmation,OperationSchedulingState.BackingOff)},nanoTime={time}) {
                assertEquals(0,diagnostics.snapshot().operationRecorded);time=30;42
            }
            assertEquals(42,result)
        }
        val value=diagnostics.snapshot().operations.single()
        assertEquals(7,value.candidateWaitNanos);assertEquals(20,value.handlerElapsedNanos)
        assertEquals(NetworkWorkPriority.Recovery,value.priority);assertEquals(2,value.attempt)
        assertEquals(OperationStepMetric.Completion.Returned,value.completion)
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown,value.certainty)
    }

    @Test fun `diagnostic read failure never changes original handler result or exception`()=runBlocking {
        val diagnostics=NetworkDiagnostics();val failure=IOException("private error")
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            assertEquals(42,measureOperationStep(OperationKind.ProfileUpdate,OperationWorkAction.Submit,1,false,System.nanoTime(),
                observe={throw IOException("private database")}) {42})
            assertSame(failure,assertFailsWith<IOException> {
                measureOperationStep(OperationKind.ProfileUpdate,OperationWorkAction.Submit,1,false,System.nanoTime(),
                    observe={throw IOException("private database")}) {throw failure}
            })
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(listOf(OperationStepMetric.Completion.Returned,OperationStepMetric.Completion.Threw),samples.map {it.completion})
        assertTrue(samples.all {it.observation==null && it.certainty==NetworkMetric.Certainty.OutcomeUnknown})
    }

    @Test fun `actual cancellation does not issue a diagnostic store read`()=runBlocking {
        val diagnostics=NetworkDiagnostics();val entered=CompletableDeferred<Unit>();var reads=0
        val task=launch(NetworkDiagnosticsScope(diagnostics)) {
            measureOperationStep(OperationKind.ContactAlias,OperationWorkAction.Submit,1,false,System.nanoTime(),observe={reads++;null}) {
                entered.complete(Unit);awaitCancellation()
            }
        }
        entered.await();task.cancelAndJoin()
        assertEquals(0,reads)
        val sample=diagnostics.snapshot().operations.single()
        assertEquals(OperationStepMetric.Completion.Cancelled,sample.completion);assertNull(sample.observation)
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown,sample.certainty)
    }

    @Test fun `account owner takes precedence and disabled instrumentation does no extra reads`()=runBlocking {
        val scheduler=AccountWorkScheduler();val foreign=NetworkDiagnostics();var reads=0
        suspend fun step()=measureOperationStep(OperationKind.ContactAlias,OperationWorkAction.Submit,1,false,System.nanoTime(),observe={reads++;null}) {Unit}
        step();assertEquals(0,reads)
        withContext(NetworkDiagnosticsScope(foreign)+NetworkWorkScope(scheduler,NetworkWorkContext("account"))) {step()}
        assertEquals(1,reads);assertEquals(1,scheduler.networkDiagnostics.snapshot().operationRecorded);assertEquals(0,foreign.snapshot().recorded)
        scheduler.closeAndDrain()
        withContext(NetworkDiagnosticsScope(foreign)+NetworkWorkScope(scheduler,NetworkWorkContext("account"))) {step()}
        assertEquals(1,reads);assertEquals(0,foreign.snapshot().recorded)
    }
}
