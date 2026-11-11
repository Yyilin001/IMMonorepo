package com.xmtx.im.client

/** Session-owned estimate from TLS server samples; never persists device monotonic instants. */
class ServerTimeAnchor(private val nanoTime: () -> Long = System::nanoTime) {
    enum class Reason { Unavailable, InvalidSample }
    class Failure(val reason: Reason) : IllegalStateException("Server time ${reason.name}")
    private data class Sample(val milliseconds: Long, val receivedAt: Long)
    private val lock = Any()
    private var sample: Sample? = null

    fun observe(milliseconds: Long, receivedAtNanos: Long = nanoTime()) = synchronized(lock) {
        if (milliseconds <= 0) throw Failure(Reason.InvalidSample)
        sample = Sample(milliseconds, receivedAtNanos)
    }

    fun reset() = synchronized(lock) { sample = null }

    fun now(atNanos: Long = nanoTime()): Long = synchronized(lock) {
        val current = sample ?: throw Failure(Reason.Unavailable)
        val elapsed = atNanos - current.receivedAt
        if (elapsed < 0 || elapsed > 3_600_000_000_000L) throw Failure(Reason.Unavailable)
        try { Math.addExact(current.milliseconds, elapsed / 1_000_000) }
        catch (_: ArithmeticException) { throw Failure(Reason.InvalidSample) }
    }
}
