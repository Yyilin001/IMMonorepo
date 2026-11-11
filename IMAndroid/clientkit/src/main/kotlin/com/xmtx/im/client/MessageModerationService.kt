package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

data class ModerationConfirmation(val intent: ModerationIntent,val activation: String,val deadlineNanos: Long)
class MessageModerationService(private val actor: UserId,private val client: MessageModerationClient,private val store: ModerationStore,
    private val now: () -> Long = System::currentTimeMillis,private val mono: () -> Long = System::nanoTime) {
    private val activation = UUID.randomUUID().toString()
    private val submissionEnds = mutableMapOf<String,Long>()
    private val roundEnds = mutableMapOf<String,Long>()
    private val mutex = Mutex()
    fun confirmation(baseline: ModerationBaseline,reason: String) = ModerationConfirmation(
        ModerationIntent(actor,baseline.room,UUID.randomUUID().toString().uppercase(),baseline.message,moderationReason(reason),baseline.messageRevision,baseline.membershipRevision,Math.addExact(now(),115000)),activation,mono()+115000000000)
    suspend fun enqueue(value: ModerationConfirmation) = mutex.withLock {
        require(value.activation == activation && value.intent.actor == actor && value.intent.deadline > now() && value.intent.deadline-now() <= 120000 && value.deadlineNanos > mono() && value.deadlineNanos-mono() <= 120000000000)
        store.enqueueModeration(ModerationWork(value.intent,activation,roundEnd = now()+60000,executionStarted = false)).also {
            submissionEnds[it.intent.key] = minOf(submissionEnds[it.intent.key] ?: value.deadlineNanos,value.deadlineNanos)
            roundEnds.putIfAbsent(it.intent.key,mono()+(it.roundEnd-now()).coerceIn(0,60000)*1000000)
        }
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = owned(id);require(!work.terminal)
        store.updateModeration(work,work.copy(status = ModerationStatus.Pending,attempts = 0,roundEnd = now()+60000));roundEnds[id] = mono()+60000000000
    }
    private suspend fun owned(id: String) = store.moderationWorks().first { it.intent.key == id }.also { require(it.intent.actor == actor) }
    suspend fun flush() = mutex.withLock {
        val candidates = store.moderationWorks(); val candidatesObserved = System.nanoTime()
        for(work in candidates) { require(work.intent.actor == actor);if(work.status == ModerationStatus.Pending) execute(work, candidatesObserved) }
    }
    private suspend fun execute(saved: ModerationWork, candidatesObserved: Long) {
        val id = saved.intent.key
        val round = roundEnds.getOrPut(id) { mono()+(saved.roundEnd-now()).coerceIn(0,60000)*1000000 }
        if(saved.attempts >= 5 || round <= mono() || saved.roundEnd <= now()) { store.updateModeration(saved,saved.copy(status = ModerationStatus.NeedsAttention));return }
        if(saved.nextAttempt > now()) return
        val wallEnd = minOf(saved.intent.deadline,saved.admission?.expires ?: saved.intent.deadline)
        val previousEnd = submissionEnds.getOrPut(id) { mono()+(wallEnd-now()).coerceIn(0,120000)*1000000 }
        val end = minOf(previousEnd,mono()+(wallEnd-now()).coerceIn(0,120000)*1000000);submissionEnds[id] = end
        val close = saved.recoveryOnly || wallEnd <= now() || end <= mono() || (saved.admission == null && saved.activation != activation)
        val recover = close || saved.reconcile || saved.executionStarted == null
        val admit = !recover && saved.admission == null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,attempts = saved.attempts+1,reconcile = true,recoveryOnly = close,submissionStarted = saved.submissionStarted || (!recover && !admit))
        store.updateModeration(saved,work)
        measureOperationStep(OperationKind.Moderation, if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            work.attempts, isRetry, candidatesObserved,
            observe = { store.moderationWork(id)?.takeIf { work.intent == it.intent }?.operationObservation(now()) }) {
            val next = try {
                val budget = minOf(15000,((round-mono())/1000000).coerceAtLeast(1),if(recover) 15000 else ((end-mono())/1000000).coerceAtLeast(1))
                if(admit) {
                    when(val result = withTimeout(budget) { withCommandAttempt(isRetry) { client.admit(work.intent) } }) {
                        is ModerationAdmissionResult.Admitted -> work.copy(admission = result.value,reconcile = false,nextAttempt = 0,reason = null)
                        is ModerationAdmissionResult.Terminal -> terminal(work,result.receipt)
                        is ModerationAdmissionResult.Unavailable -> work.copy(status = ModerationStatus.NeedsAttention,reconcile = false,reason = result.reason)
                        ModerationAdmissionResult.Conflict -> work.copy(status = ModerationStatus.NeedsAttention,reason = "fingerprintConflict")
                    }
                } else when(val result = withTimeout(budget) { withCommandAttempt(isRetry) { client.execute(work.intent,work.command(),recover,close) } }) {
                    is ModerationResult.Receipt -> terminal(work,result)
                    is ModerationResult.Deferred -> work.copy(nextAttempt = Math.addExact(now(),maxOf(5000,result.delay)))
                    ModerationResult.Unresolved -> work.copy(reconcile = close,nextAttempt = now()+5000)
                    ModerationResult.Conflict -> work.copy(status = ModerationStatus.NeedsAttention,reason = "fingerprintConflict")
                }
            } catch(e: TimeoutCancellationException) { deferred(work,0,false) }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                val deferred = deferred(work,(e as? ModerationBackpressure)?.delay ?: 0,e is IllegalArgumentException || e is ClientFailure.Protocol)
                if(e is ClientFailure.SignedOut) { store.updateModeration(work,deferred);throw e };deferred
            }
            store.updateModeration(work,if(!next.terminal && (next.attempts >= 5 || round <= mono())) next.copy(status = ModerationStatus.NeedsAttention) else next)
        }
    }
    private fun terminal(work: ModerationWork,receipt: ModerationResult.Receipt) = work.copy(status = receipt.status,receipt = receipt.wire,reason = receipt.reason)
    private fun deferred(work: ModerationWork,floor: Long,stop: Boolean) = work.copy(status = if(stop) ModerationStatus.NeedsAttention else ModerationStatus.Pending,
        nextAttempt = Math.addExact(now(),maxOf(1000L shl minOf(work.attempts,5),floor)),reason = "confirmationRequired")
}
