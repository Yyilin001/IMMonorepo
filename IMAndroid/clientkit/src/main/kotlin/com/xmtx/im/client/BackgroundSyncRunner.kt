package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.coroutines.*
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select
import java.io.IOException

/** Shared personal/room page budget. Work expiry does not bound transport cleanup time. */
data class BackgroundSyncBudget(val maximumPages: Int = 4, val workDurationMillis: Long = 25_000) {
    init { require(maximumPages in 1..10_000 && workDurationMillis in 1..Long.MAX_VALUE / 1_000_000) }
}
class BackgroundSyncDeadlineReached : IOException("Background sync deadline reached")

/** A dedicated background connection, never the foreground socket. Disconnect must be idempotent
 * and immediately stop actual I/O, including a handshake. The runner joins work after disconnect. */
interface BackgroundSyncConnection {
    suspend fun connect()
    fun disconnect()
}

/** Dedicated realtime adapter. Account identity is revalidated before and after the handshake;
 * one explicit access rejection may refresh within that same account epoch. */
class RealtimeBackgroundSyncConnection internal constructor(private val connection: RealtimeConnection,
    private val credentials: suspend (rejectedAccess: Credentials?) -> Credentials,
    private val validateIdentity: suspend (Credentials) -> Unit = {},
    private val scheduler: AccountWorkScheduler? = null) : BackgroundSyncConnection, EnvelopeTransport {
    constructor(connection: RealtimeConnection, auth: AuthSession, identity: LocalAccountIdentity,
        scheduler: AccountWorkScheduler? = null) : this(connection,
        { rejected -> auth.access(rejectedAccess = rejected, expectedEpoch = identity.epoch) },
        { value ->
            auth.requireLocalIdentity(identity)
            if (value.userId != identity.userId || value.deviceId != identity.deviceId) throw ClientFailure.SessionInvalidated()
        }, scheduler)
    override suspend fun connect() {
        try {
            var value = credentials(null)
            currentCoroutineContext().ensureActive(); validateIdentity(value)
            try { connection.connect(value, scheduler) }
            catch (error: GatewayFailure) {
                if (error.code != "UNAUTHENTICATED" || error.retryable) throw error
                val refreshed = credentials(value)
                currentCoroutineContext().ensureActive()
                if (refreshed.userId != value.userId || refreshed.deviceId != value.deviceId) throw ClientFailure.SignedOut()
                validateIdentity(refreshed)
                connection.connect(refreshed, scheduler) // Exactly one rejection refresh, never a reconnect loop.
                value = refreshed
            }
            validateIdentity(value); currentCoroutineContext().ensureActive()
        } catch (error: Throwable) { connection.close(); throw error }
    }
    override fun disconnect() = connection.close()
    override suspend fun request(body: Envelope.Builder): Envelope = connection.request(body)
}

/** Concurrent callers join one bounded operation. The supplied account scope owns actual work;
 * cancelling any waiter leaves shared work running. Call stop before closing the account store.
 * stop is reusable and may be called concurrently or from an already-cancelled caller.
 */
class BackgroundSyncRunner(private val connection: BackgroundSyncConnection, private val engine: SyncEngine,
    private val scope: CoroutineScope, private val roomSync: (suspend (Int) -> IncrementalSyncResult)? = null,
    private val budget: BackgroundSyncBudget = BackgroundSyncBudget(),
    private val nanoTime: () -> Long = System::nanoTime) {
    private class Flight(val task: Deferred<Result<IncrementalSyncResult>>)
    private val lock = Any()
    private val accountJob = requireNotNull(scope.coroutineContext[Job])
    private var flight: Flight? = null
    private var stopping: Deferred<Result<Unit>>? = null
    private var retirementFailure: Throwable? = null

    /** Absolute deadline from the same monotonic nanoTime source. The initiating deadline limits
     * shared work; later callers' earlier deadlines only limit their own wait. */
    suspend fun run(deadlineNanos: Long? = null): IncrementalSyncResult {
        currentCoroutineContext().ensureActive(); accountJob.ensureActive()
        if (deadlineNanos != null && deadlineNanos - nanoTime() <= 0) throw BackgroundSyncDeadlineReached()
        val (operation, joined) = synchronized(lock) {
            accountJob.ensureActive()
            if (stopping != null) throw CancellationException("Background sync is stopping")
            retirementFailure?.let { throw IllegalStateException("Background transport retirement failed", it) }
            val existing = flight
            if (existing != null && !existing.task.isCompleted) existing to true
            else {
                // LAZY installs identity before an immediate dispatcher can finish the operation.
                val task = scope.async(start = CoroutineStart.LAZY) { runCatching { catchUp(deadlineNanos) } }
                val created = Flight(task); flight = created
                task.invokeOnCompletion { synchronized(lock) { if (flight === created) flight = null } }
                created to false
            }
        }
        operation.task.start()
        return if (joined && deadlineNanos != null) awaitUntil(operation.task, deadlineNanos).getOrThrow()
            else operation.task.await().getOrThrow()
    }

    /** Reject new work, cancel and close the dedicated connection, then join the same shared drain.
     * This never closes the local store. Successful stop also permits retry after a failed disconnect. */
    suspend fun stop() = withContext(NonCancellable) {
        val drain = synchronized(lock) {
            stopping ?: run {
                val current = flight
                val cleanup = CoroutineScope(scope.coroutineContext.minusKey(Job))
                val task = cleanup.async(start = CoroutineStart.LAZY) { runCatching {
                    current?.task?.cancel()
                    try { disconnect() } finally { current?.task?.join() }
                    synchronized(lock) { retirementFailure = null }
                } }
                stopping = task
                task.invokeOnCompletion { synchronized(lock) { if (stopping === task) stopping = null } }
                task
            }
        }
        drain.start(); drain.await().getOrThrow()
    }

    private fun disconnect() {
        try { connection.disconnect() }
        catch (error: Throwable) { synchronized(lock) { retirementFailure = error }; throw error }
    }
    private suspend fun catchUp(callerDeadline: Long?): IncrementalSyncResult = supervisorScope {
        val started = nanoTime()
        val remaining = minOf(budget.workDurationMillis * 1_000_000,
            callerDeadline?.let { it - started } ?: Long.MAX_VALUE)
        val deadline = started + remaining
        val work = async(start = CoroutineStart.LAZY) {
            connection.connect(); currentCoroutineContext().ensureActive()
            val personalBudget = if (roomSync == null) budget.maximumPages else maxOf(1, budget.maximumPages / 2)
            val personal = engine.synchronizeIncrementally(personalBudget)
            val remainingPages = budget.maximumPages - personal.processedPageCount
            if (personal.stopReason == IncrementalSyncStopReason.ResetPending || roomSync == null || remainingPages == 0) personal
            else {
                currentCoroutineContext().ensureActive()
                val rooms = roomSync.invoke(remainingPages); currentCoroutineContext().ensureActive()
                require(rooms.processedPageCount in 0..remainingPages)
                IncrementalSyncResult(personal.processedPageCount + rooms.processedPageCount,
                    personal.didCommitNewRecords || rooms.didCommitNewRecords,
                    if (personal.stopReason == IncrementalSyncStopReason.PageLimit || rooms.stopReason != IncrementalSyncStopReason.CaughtUp)
                        IncrementalSyncStopReason.PageLimit else IncrementalSyncStopReason.CaughtUp)
            }
        }
        try {
            if (remaining <= 0) throw BackgroundSyncDeadlineReached()
            work.start(); awaitUntil(work, deadline)
        } finally {
            withContext(NonCancellable) {
                work.cancel()
                try { disconnect() } finally { work.join() }
            }
        }
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun <T> awaitUntil(task: Deferred<T>, deadline: Long): T {
        val remaining = deadline - nanoTime()
        if (remaining <= 0) throw BackgroundSyncDeadlineReached()
        val millis = remaining / 1_000_000 + if (remaining % 1_000_000 == 0L) 0 else 1
        return select {
            task.onAwait { it }
            onTimeout(millis) { throw BackgroundSyncDeadlineReached() }
        }
    }
}
