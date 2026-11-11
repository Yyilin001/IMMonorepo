package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlin.test.*
import kotlin.coroutines.EmptyCoroutineContext

class ResourceTransferMetricsTests {
    private fun sample(status:Int?=200,mode:ResourceTransferMetric.Mode=ResourceTransferMetric.Mode.RangeDownload)=
        ResourceTransferMetric(mode,status,0,8,1,false,false,false)
    @Test fun `response categories distinguish full range rebuild partial and unsatisfied`() {
        assertEquals(ResourceTransferMetric.Response.Absent,sample(null).response)
        assertEquals(ResourceTransferMetric.Response.PartialResponse,sample(206).response)
        assertEquals(ResourceTransferMetric.Response.FullResponseForRange,sample(200).response)
        assertEquals(ResourceTransferMetric.Response.RangeUnsatisfied,sample(416).response)
        assertEquals(ResourceTransferMetric.Response.SuccessStatus,sample(200,ResourceTransferMetric.Mode.Download).response)
        assertEquals(ResourceTransferMetric.Response.Other,sample(503).response)
        assertFailsWith<IllegalArgumentException> {sample().copy(verifiedRangeRebuildPrefixBytes=9)}
        assertFailsWith<IllegalArgumentException> {sample(206).copy(verifiedRangeRebuildPrefixBytes=4)}
        assertNull(sample().verifiedRangeRebuildPrefixBytes)
    }
    @Test fun `diagnostics retain a bounded immutable window and reject late samples after close`()=runBlocking {
        val diagnostics=ResourceTransferDiagnostics();diagnostics.record(sample());val old=diagnostics.snapshot()
        coroutineScope {repeat(4) {launch(Dispatchers.Default) {repeat(100) {diagnostics.record(sample())}}}}
        assertEquals(401,diagnostics.snapshot().recorded);assertEquals(128,diagnostics.snapshot().samples.size)
        assertEquals(1,old.recorded);assertEquals(1,old.samples.size)
        diagnostics.close();diagnostics.record(sample());assertEquals(401,diagnostics.snapshot().recorded)
        assertTrue(diagnostics.snapshot().closed);assertTrue(diagnostics.snapshot().samples.isEmpty());assertEquals(1,old.samples.size)
    }
    @Test fun `measurement belongs to account scope ignores unstarted work and publishes once after drain`()=runBlocking {
        val scheduler=AccountWorkScheduler();val foreign=ResourceTransferDiagnostics();var clock=10L
        val context=NetworkWorkScope(scheduler,NetworkWorkContext("mediaProvider"))+NetworkWorkIntent(NetworkWorkPriority.Recovery,true)+ResourceTransferDiagnosticsScope(foreign)
        try {
            assertNull(ResourceTransferMeasurement(context,ResourceTransferMetric.Mode.Upload) {clock}.finish())
            val measurement=ResourceTransferMeasurement(context,ResourceTransferMetric.Mode.Upload) {clock}
            measurement.start();measurement.sent(3);measurement.headers(503);measurement.received(2);measurement.cancel();clock=30
            val completed=measurement.finish()!!;assertNull(measurement.finish());completed.record();completed.record()
            val result=scheduler.transferDiagnostics.snapshot();assertEquals(1,result.recorded);assertEquals(0,foreign.snapshot().recorded)
            val sample=result.samples.single();assertEquals(20,sample.elapsedNanos);assertEquals(3,sample.bodyBytesSent);assertEquals(2,sample.bodyBytesReceived)
            assertTrue(sample.retryAttempt);assertTrue(sample.cancelled);assertTrue(sample.failed)
            assertEquals(NetworkQualityObserver.Quality.Normal,scheduler.serviceQuality("mediaProvider"))
        } finally {scheduler.closeAndDrain()}
        assertTrue(scheduler.transferDiagnostics.snapshot().closed);assertTrue(scheduler.transferDiagnostics.snapshot().samples.isEmpty())
        val standalone=ResourceTransferMeasurement(EmptyCoroutineContext,ResourceTransferMetric.Mode.Upload);standalone.start();assertNull(standalone.finish())
    }
}
