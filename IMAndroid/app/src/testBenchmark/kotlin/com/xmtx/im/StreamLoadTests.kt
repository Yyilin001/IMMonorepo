package com.xmtx.im

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class StreamLoadTests {
    @Test fun exactRateIncludesFractionalBucketsWithoutDependingOnUi() = runBlocking {
        for (rate in listOf(1, 123, 500, 1_000)) {
            var time = 0L; var written = 0; val bucketSizes = mutableListOf<Int>()
            val result = StreamLoad(rate, 5).produce({ time }, { time = maxOf(time, it) }, { offset, size ->
                assertEquals(written, offset); written += size; bucketSizes += size
            }, { assertEquals(written, it.messages) })
            assertEquals(rate * 5, written); assertEquals(written, result.withinWindow)
            assertEquals(5_000.0, result.elapsedMs, 0.01); assertTrue(bucketSizes.all { it in 1..100 })
        }
    }
    @Test fun slowWriterReportsMissedLoadWithoutDroppingOrCatchUpBursts() = runBlocking {
        var time = 0L; var last = -100_000_000L; var written = 0
        val result = StreamLoad(1_000, 5).produce({ time }, { time = maxOf(time, it) }, { offset, size ->
            assertEquals(written, offset); assertTrue(time - last >= 100_000_000L)
            last = time; time += 150_000_000; written += size
        }, {})
        assertEquals(5_000, written); assertTrue(result.withinWindow < written)
        assertTrue(result.maximumBacklog > 100); assertTrue(result.maximumLatenessMs > 0)
    }
    @Test fun cancellationStopsTheOriginalProducer() = runBlocking {
        var time = 0L; var calls = 0
        try {
            StreamLoad(1_000, 5).produce({ time }, { time = maxOf(time, it) }, { _, _ ->
                calls++; if (calls == 3) throw CancellationException()
            }, {})
            fail("cancellation swallowed")
        } catch (_: CancellationException) { }
        assertEquals(3, calls)
    }
    @Test fun invalidLoadCannotExceedTheRequestedCeiling() {
        for ((rate, seconds) in listOf(0 to 5, 1001 to 5, 1000 to 0, 1000 to 121)) {
            assertThrows(IllegalArgumentException::class.java) { StreamLoad(rate, seconds) }
        }
    }
}
