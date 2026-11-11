package com.xmtx.im.client

import kotlinx.serialization.json.*
import kotlin.test.*

class ResourceBackgroundTransferMetricsTests {
    @Test fun `missing and legacy observations keep counters and transport outcome unknown`() {
        val unknown=ResourceBackgroundTransferMetric.from(null,12)
        assertFalse(unknown.completionObserved);assertNull(unknown.bodyBytesSent);assertNull(unknown.bodyBytesReceived)
        assertNull(unknown.statusCode);assertNull(unknown.transportFailed);assertNull(unknown.cancelled);assertEquals(12,unknown.cancellationToPermitReleaseNanos)
        assertNull(ResourceBackgroundTransferMetric.from(null,-1).cancellationToPermitReleaseNanos)
        val zero=ResourceBackgroundTransferMetric.from(ResourceBackgroundTransferObservation(0,0,null,true,true))
        assertTrue(zero.completionObserved);assertEquals(0,zero.bodyBytesSent);assertEquals(0,zero.bodyBytesReceived);assertEquals(true,zero.transportFailed);assertEquals(true,zero.cancelled)
    }
    @Test fun `persisted observation preserves only drained transport facts`() {
        val sample=ResourceTransferMetric(ResourceTransferMetric.Mode.MultipartUpload,503,4,12,999,true,false,false)
        val observation=ResourceBackgroundTransferObservation.from(sample)
        val encoded=observation.payload();assertEquals(setOf("sent","received","status","failed","cancelled"),encoded.keys)
        val restored=ResourceBackgroundTransferObservation.decode(Json.parseToJsonElement(encoded.toString()).jsonObject)
        assertEquals(observation,restored)
        val metric=ResourceBackgroundTransferMetric.from(restored)
        assertEquals(503,metric.statusCode);assertEquals(4,metric.bodyBytesSent);assertEquals(12,metric.bodyBytesReceived)
        assertEquals(false,metric.transportFailed);assertEquals(false,metric.cancelled);assertNull(metric.cancellationToPermitReleaseNanos)
        assertFailsWith<IllegalArgumentException> {restored.copy(bodyBytesReceived=-1)}
    }
    @Test fun `resource and background windows have separate bounded immutable samples and counters`() {
        val diagnostics=ResourceTransferDiagnostics();val background=ResourceBackgroundTransferMetric.from(null)
        val resource=ResourceTransferMetric(ResourceTransferMetric.Mode.Download,200,0,8,1,false,false,false)
        diagnostics.record(background);val old=diagnostics.snapshot()
        repeat(130) {diagnostics.record(background);diagnostics.record(resource)}
        val current=diagnostics.snapshot();assertEquals(261,current.recorded);assertEquals(131,current.backgroundRecorded);assertEquals(130,current.resourceRecorded)
        assertEquals(128,current.backgrounds.size);assertEquals(128,current.samples.size);assertEquals(1,old.backgrounds.size);assertTrue(old.samples.isEmpty())
        diagnostics.close();diagnostics.record(background);assertEquals(261,diagnostics.snapshot().recorded)
        assertTrue(diagnostics.snapshot().samples.isEmpty());assertTrue(diagnostics.snapshot().backgrounds.isEmpty());assertEquals(1,old.backgrounds.size)
    }
}
