package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import java.io.Closeable
import java.io.IOException
import kotlin.time.TimeSource

private fun retryMonotonicClock(): ()->Long {val origin=TimeSource.Monotonic.markNow();return {origin.elapsedNow().inWholeMilliseconds}}

/** Immutable retry arithmetic matching iOS's five-token, one-token-per-two-seconds bucket. */
data class NetworkRetryBucket(val tokens: Int=5,val refilledAt: Long) {
    init {require(tokens in 0..5 && refilledAt>=0)}
    fun refill(now: Long): NetworkRetryBucket {
        require(now>=0)
        if(now<=refilledAt) return this
        val elapsed=now-refilledAt
        val intervals=elapsed/2000
        return if(intervals==0L) this else copy(tokens=minOf(5,tokens+minOf(5L,intervals).toInt()),refilledAt=now-elapsed%2000)
    }
}
class RetryAdmissionUnavailable(message: String): IOException(message)

/** Account-lifetime service retry quota, independent of physical transport slots and durable commands.
 * Keep the same owner across reconnects/backgrounding; close it when the account is replaced.
 * Ordinary initial attempts bypass retry tokens. All requests obey a registered service cooldown.
 * FIFO among retry waiters; no parent request/transport slot is held while waiting here.
 */
class AccountRetryAdmission(private val monotonicMillis: ()->Long=retryMonotonicClock(),
    private val maximumWaiters: Int=256,private val maximumServices: Int=64): Closeable {
    init {require(maximumWaiters>=0 && maximumServices>0)}
    private class Service(now: Long) {
        var bucket=NetworkRetryBucket(refilledAt=now)
        var cooldown=now
        val retries=ArrayDeque<Any>()
    }
    private val lock=Any();private val services=mutableMapOf<String,Service>()
    private val changed=MutableStateFlow(0L);private var closed=false;private var waiting=0
    private fun signal() {changed.value=changed.value+1}
    private fun stateFor(name: String): Service {
        require(name.isNotBlank() && name.length<=128)
        if(closed) throw RetryAdmissionUnavailable("Account retry admission closed")
        return services[name] ?: run {
            if(services.size>=maximumServices) throw RetryAdmissionUnavailable("Too many retry services")
            Service(monotonicMillis()).also {services[name]=it}
        }
    }
    fun coolDown(service: String,milliseconds: Long) = synchronized(lock) {
        require(milliseconds>=0)
        if(closed) return@synchronized
        val value=stateFor(service);val now=monotonicMillis()
        val until=if(now>Long.MAX_VALUE-milliseconds) Long.MAX_VALUE else now+milliseconds
        value.cooldown=maxOf(value.cooldown,until);signal()
    }
    suspend fun await(service: String,isRetry: Boolean,timeoutMillis: Long=15_000) {
        require(timeoutMillis>0)
        currentCoroutineContext().ensureActive()
        val ticket=Any();var registered=false
        try {val admitted=withTimeoutOrNull(timeoutMillis) {
            while(true) {
                currentCoroutineContext().ensureActive()
                val wait=synchronized(lock) {
                    val value=stateFor(service);val now=monotonicMillis();value.bucket=value.bucket.refill(now)
                    val first=!isRetry || value.retries.isEmpty() || value.retries.first()===ticket
                    if(first && now>=value.cooldown && (!isRetry || value.bucket.tokens>0)) {
                        if(isRetry) {value.bucket=value.bucket.copy(tokens=value.bucket.tokens-1);if(registered) value.retries.remove(ticket)}
                        if(registered) {waiting--;registered=false;signal()}
                        null
                    } else {
                        if(!registered) {
                            if(waiting>=maximumWaiters) throw RetryAdmissionUnavailable("Retry admission queue full")
                            waiting++;registered=true;if(isRetry) value.retries.addLast(ticket)
                        }
                        val due=maxOf(value.cooldown,if(isRetry && value.bucket.tokens==0) if(value.bucket.refilledAt>Long.MAX_VALUE-2000) Long.MAX_VALUE else value.bucket.refilledAt+2000 else now)
                        // Followers wake when the head leaves. Only eligible heads need a timer.
                        changed.value to if(first && due>now) due-now else null
                    }
                }
                if(wait==null) return@withTimeoutOrNull true
                if(wait.second==null) changed.first {it!=wait.first}
                else withTimeoutOrNull(wait.second!!) {changed.first {it!=wait.first}}
            }
        };if(admitted!=true) throw RetryAdmissionUnavailable("Retry admission deadline exceeded")} finally {synchronized(lock) {
            if(registered) {services[service]?.retries?.remove(ticket);waiting--;signal()}
        }}
    }
    override fun close() = synchronized(lock) {if(!closed) {closed=true;signal()}}
}
