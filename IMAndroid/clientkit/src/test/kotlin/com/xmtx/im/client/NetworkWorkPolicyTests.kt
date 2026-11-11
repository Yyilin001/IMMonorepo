package com.xmtx.im.client

import kotlin.test.*

class NetworkWorkPolicyTests {
    @Test fun `retry after retains jitter and strict original budget`() {
        val p=NetworkWorkPolicy.InteractiveRead
        assertEquals(listOf(5000L,5250L,5500L),listOf(0.0,0.5,1.0).map {p.nextAttempt(0,0,1,it,5000)})
        assertEquals(250L,p.nextAttempt(0,0,1,0.5))
        assertEquals(9875L,p.nextAttempt(0,0,1,0.5,9750))
        assertNull(p.nextAttempt(0,0,1,1.0,9750));assertNull(p.nextAttempt(0,0,1,0.0,10_000))
        assertNull(p.nextAttempt(0,0,2,0.0));assertNull(p.nextAttempt(10_000,0,1,0.0))
    }
    @Test fun `recovery backoff and bounded random values match Swift policy`() {
        val p=NetworkWorkPolicy.CommandRecovery
        assertEquals(listOf(500L,1000L,2000L,4000L),(1..4).map {p.nextAttempt(0,0,it,1.0)})
        assertEquals(5000L,p.nextAttempt(0,0,1,Double.NEGATIVE_INFINITY,5000))
        assertEquals(5500L,p.nextAttempt(0,0,1,Double.POSITIVE_INFINITY,5000))
        assertEquals(5000L,p.nextAttempt(0,0,1,Double.NaN,5000))
        assertNull(p.nextAttempt(0,0,5,0.0))
    }
    @Test fun `accepted and processing poll floors are not retry attempts`() {
        assertEquals(listOf(2000L,5000L,10_000L,30_000L,30_000L),(0..4).map {NetworkWorkPolicy.acceptedResultPollDelayMillis(it)})
        assertEquals(40_000L,NetworkWorkPolicy.acceptedResultPollDelayMillis(0,40_000))
        assertEquals(listOf(500L,500L,500L,500L,750L,1000L,2000L,5000L,10_000L,30_000L),(0..9).map {NetworkWorkPolicy.resourceProcessingPollDelayMillis(it)})
        assertEquals(900L,NetworkWorkPolicy.resourceProcessingPollDelayMillis(0,900))
    }
}
