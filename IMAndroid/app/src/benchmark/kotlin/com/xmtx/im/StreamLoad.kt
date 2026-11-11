package com.xmtx.im

/** Fixed 100 ms input buckets, independent of rendering. A slow writer never gets an unbounded catch-up burst. */
internal class StreamLoad(val rate: Int, val seconds: Int) {
    init { require(rate in 1..1_000 && seconds in 5..120) }
    val expected get() = rate * seconds
    data class Commit(val messages: Int = 0, val atNanos: Long = 0, val scheduledNanos: Long = 0)
    data class Result(val committed: Int, val withinWindow: Int, val elapsedMs: Double,
        val maximumBacklog: Int, val maximumLatenessMs: Double)

    suspend fun produce(now: () -> Long, sleepUntil: suspend (Long) -> Unit,
        write: (offset: Int, count: Int) -> Unit, committed: (Commit) -> Unit): Result {
        val period = 100_000_000L
        val start = now(); val end = start + seconds * 1_000_000_000L
        var previousStart = start - period
        var total = 0; var within = 0; var backlog = 0; var lateness = 0L
        repeat(seconds * 10) { tick ->
            val scheduled = start + tick * period
            sleepUntil(maxOf(scheduled, previousStart + period))
            val actual = now(); previousStart = actual
            lateness = maxOf(lateness, actual - scheduled)
            val offered = minOf(expected.toLong(), rate.toLong() * ((actual - start) / period + 1) / 10).toInt()
            backlog = maxOf(backlog, offered - total)
            val size = rate * (tick + 1) / 10 - rate * tick / 10
            if (size > 0) {
                write(total, size)
                total += size
                val time = now()
                if (time <= end) within += size
                committed(Commit(total, time, scheduled))
            }
        }
        sleepUntil(end)
        return Result(total, within, (now() - start) / 1_000_000.0, backlog, lateness / 1_000_000.0)
    }
}
