package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlin.test.*

class ProjectionMetricsTests {
    @Test fun `projection window is bounded deeply immutable and closed owner rejects late publication`()=runBlocking {
        val diagnostics=NetworkDiagnostics();val scopes=persistentSetOf(ProjectionScope.Conversations)
        diagnostics.record(ProjectionMetric(ProjectionMetric.Phase.Commit,1,scopes));val before=diagnostics.snapshot()
        coroutineScope {repeat(4) {launch(Dispatchers.Default) {repeat(100) {diagnostics.record(ProjectionMetric(ProjectionMetric.Phase.Commit,2,scopes))}}}}
        assertEquals(401,diagnostics.snapshot().projectionRecorded);assertEquals(128,diagnostics.snapshot().projections.size)
        assertEquals(1,before.projections.size);assertEquals(scopes,before.projections.single().scopes)
        val pending=ConversationCommitMeasurement(1,diagnostics) {2};diagnostics.close();pending.didPublishSnapshot()
        assertEquals(401,diagnostics.snapshot().recorded);assertTrue(diagnostics.snapshot().projections.isEmpty())
    }
    @Test fun `coalescing chooses earliest unconsumed commit and concurrent publication records once`()=runBlocking {
        val diagnostics=NetworkDiagnostics();val first=ConversationCommitMeasurement(10,diagnostics) {40}
        val second=ConversationCommitMeasurement(20,diagnostics) {50}
        assertSame(first,ConversationCommitMeasurement.earliest(second,first))
        coroutineScope {repeat(8) {launch(Dispatchers.Default) {first.didPublishSnapshot()}}}
        assertEquals(30,diagnostics.snapshot().projections.single().elapsedNanos)
        assertSame(second,ConversationCommitMeasurement.earliest(first,second));second.didPublishSnapshot()
        assertNull(ConversationCommitMeasurement.earliest(first,second));assertEquals(2,diagnostics.snapshot().projectionRecorded)
    }
    @Test fun `cancelled publication does not consume its stamp or invent visibility`()=runBlocking {
        val diagnostics=NetworkDiagnostics();val stamp=ConversationCommitMeasurement(0,diagnostics) {5}
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val task=launch {entered.complete(Unit);try {release.await()} finally {stamp.didPublishSnapshot()}}
        entered.await();task.cancelAndJoin();assertEquals(0,diagnostics.snapshot().projectionRecorded)
        stamp.didPublishSnapshot();assertEquals(1,diagnostics.snapshot().projectionRecorded)
    }
}
