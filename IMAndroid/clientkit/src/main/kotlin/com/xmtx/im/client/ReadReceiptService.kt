package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable

@Serializable enum class ReadStatus { Pending,NeedsAttention,Confirmed,Archived }
@Serializable data class ReadWork(val command: ReadCommand,val status: ReadStatus = ReadStatus.Pending,
    val submissionStarted: Boolean = false,val reconcile: Boolean = false,val attempts: Int = 0,val nextAttempt: Long = 0,
    val roundStarted: Long? = null,val watermark: ReadWatermark? = null,val originalReceipt: Boolean? = null,
    val reason: String? = null,val control: Boolean = false,val archivedAt: Long? = null) {
    init {
        require(attempts >= 0 && nextAttempt >= 0 && (roundStarted == null || roundStarted >= 0))
        require(!control || submissionStarted && reconcile)
        require((watermark == null) == (originalReceipt == null));watermark?.validate(command)
        require((status == ReadStatus.Confirmed) == (watermark != null));require(status != ReadStatus.Confirmed || submissionStarted)
        require((status == ReadStatus.Archived) == (archivedAt != null));require(archivedAt == null || archivedAt >= 0)
    }
    val active get() = status in setOf(ReadStatus.Pending,ReadStatus.NeedsAttention)
}
interface ReadReceiptStore {
    suspend fun enqueueRead(room: RoomId,sequence: Long): Boolean
    suspend fun prepareReads(limit: Int = 16)
    suspend fun readWorks(): PersistentList<ReadWork>
    /** Exact journal observation; persistent adapters use the operation primary key. */
    suspend fun readWork(operation:String): ReadWork? = readWorks().firstOrNull {it.command.operation==operation}
    suspend fun updateRead(expected: ReadWork,updated: ReadWork)
    suspend fun allowsReadPublication(room: RoomId): Boolean
    suspend fun archiveRead(operation: String,now: Long)
    suspend fun restoreRead(operation: String,now: Long)
    /** Transfer the same frozen operation from recovery capacity before any resubmit. */
    suspend fun admitReadResubmission(expected: ReadWork,updated: ReadWork)
}
class ReadReceiptService(private val actor: UserId,private val client: ReadReceiptTransport,private val store: ReadReceiptStore,
    private val now: () -> Long = System::currentTimeMillis,private val monotonic: () -> Long = { System.nanoTime()/1000000 },private val batchSize: Int = 16) {
    init { require(batchSize in 1..100) }
    private val mutex = Mutex()
    private val rounds = mutableMapOf<String,Pair<Long,Long>>()
    suspend fun enqueue(room: RoomId,sequence: Long) = store.enqueueRead(room,sequence)
    suspend fun retry(operation: String) = mutex.withLock {
        val old = store.readWorks().first { it.command.operation == operation };require(old.command.actor == actor && old.status == ReadStatus.NeedsAttention)
        store.updateRead(old,old.copy(status = ReadStatus.Pending,attempts = 0,roundStarted = null,reconcile = old.submissionStarted,reason = null));rounds.remove(operation)
    }
    suspend fun archive(operation: String) = mutex.withLock { store.archiveRead(operation,now());rounds.remove(operation) }
    suspend fun restore(operation: String) = mutex.withLock { store.restoreRead(operation,now());rounds.remove(operation) }
    suspend fun flush() = mutex.withLock {
        currentCoroutineContext().ensureActive();store.prepareReads()
        val visited = mutableSetOf<RoomId>();var attempted = 0
        val candidates=store.readWorks();val candidatesObserved=System.nanoTime()
        for(saved in candidates) {
            require(saved.command.actor == actor)
            if(!saved.active || (!saved.control && !visited.add(saved.command.room)) || saved.status != ReadStatus.Pending || saved.nextAttempt > now()) continue
            if(attempted++ >= batchSize) break
            val start = saved.roundStarted ?: now()
            val round = rounds.getOrPut(saved.command.operation) { start to monotonic() }
            if(saved.attempts >= 5 || now() < start || now()-start >= 60000 || monotonic()-round.second !in 0 until 60000) {
                store.updateRead(saved,saved.copy(status = ReadStatus.NeedsAttention,reason = "confirmationRequired"));continue
            }
            if(!saved.reconcile && !store.allowsReadPublication(saved.command.room)) {
                store.updateRead(saved,saved.copy(status = ReadStatus.NeedsAttention,reason = "privacyPaused"));continue
            }
            val work = saved.copy(submissionStarted = true,reconcile = true,attempts = saved.attempts+1,roundStarted = start)
            store.updateRead(saved,work) // Persist uncertainty before any physical request, including query.
            measureOperationStep(OperationKind.ReadReceipt,
                if(saved.reconcile) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                work.attempts,saved.submissionStarted,candidatesObserved,
                observe={store.readWork(work.command.operation)?.takeIf {it.command==work.command}?.operationObservation(now())}) {
            try {
                val remaining = minOf(15000,60000-(now()-start),60000-(monotonic()-round.second)).coerceAtLeast(1)
                val result = withTimeout(remaining) { withCommandAttempt(saved.submissionStarted) {
                    if(saved.reconcile) client.recover(work.command) else client.submit(work.command)
                } }
                currentCoroutineContext().ensureActive()
                when(result) {
                    is ReadResult.Confirmed -> {
                        result.watermark.validate(work.command)
                        store.updateRead(work,work.copy(status = ReadStatus.Confirmed,watermark = result.watermark,originalReceipt = result.original,reason = null));rounds.remove(work.command.operation)
                    }
                    is ReadResult.Unavailable -> store.updateRead(work,work.copy(status = ReadStatus.NeedsAttention,reason = "currentUnavailable:"+result.reason))
                    ReadResult.Conflict -> store.updateRead(work,work.copy(status = ReadStatus.NeedsAttention,reason = "fingerprintConflict"))
                    ReadResult.Unresolved -> {
                        val next = retryWork(work,start,round.second,listOf(2000L,5000L,10000L,30000L)[minOf(work.attempts,3)],"unresolved").copy(reconcile = false,control = false)
                        if(work.control) store.admitReadResubmission(work,next) else store.updateRead(work,next)
                    }
                }
            } catch(e: TimeoutCancellationException) {
                currentCoroutineContext().ensureActive();store.updateRead(work,retryWork(work,start,round.second,delay(work),"confirmationRequired"))
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                currentCoroutineContext().ensureActive()
                val gateway = e as? GatewayFailure
                val floor = maxOf((e as? ReadBackpressure)?.delay ?: 0,(gateway?.retryAfterSeconds?.toLong() ?: 0).coerceAtLeast(0)*1000)
                val malformed = e is ClientFailure.Protocol || e is IllegalArgumentException
                val next = retryWork(work,start,round.second,maxOf(delay(work),floor),"confirmationRequired")
                store.updateRead(work,if(malformed) next.copy(status = ReadStatus.NeedsAttention) else next)
                if(e is ClientFailure.SignedOut || gateway?.code in setOf("UNAUTHENTICATED","SESSION_REVOKED","DEVICE_REVOKED")) throw e
            }
            }
        }
    }
    private fun delay(work: ReadWork) = minOf(30000,500L shl minOf(work.attempts-1,16))
    private fun retryWork(work: ReadWork,start: Long,monoStart: Long,delay: Long,reason: String): ReadWork {
        val at = Math.addExact(now(),delay)
        val exhausted = work.attempts >= 5 || now() < start || at-start >= 60000 || monotonic()-monoStart !in 0 until 60000
        return work.copy(status = if(exhausted) ReadStatus.NeedsAttention else ReadStatus.Pending,nextAttempt = at,reason = reason)
    }
}
