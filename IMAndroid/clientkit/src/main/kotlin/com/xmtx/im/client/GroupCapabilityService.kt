package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Memory-only authority for one click. Reopening an app never resurrects an unadmitted draft's confirmation. */
data class GroupCapabilityConfirmation(val intent: GroupCapabilityIntent, val deadlineNanos: Long, val activation: String)
class GroupCapabilityService(private val account: UserId, private val client: GroupCapabilityClient, private val store: GroupCapabilityStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime) {
    private val activation = UUID.randomUUID().toString()
    private val confirmations = mutableMapOf<String, Long>()
    private val preparationEnds = mutableMapOf<String, Long>()
    private val executionEnds = mutableMapOf<String, Long>()
    private val mutex = Mutex()
    fun confirmation(room: RoomId, action: GroupAction): GroupCapabilityConfirmation = GroupCapabilityConfirmation(
        GroupCapabilityIntent(account, room, UUID.randomUUID().toString().uppercase(), action,
            Math.addExact(now(), ClientSubmissionWindow.CONFIRMATION_MILLISECONDS)),
        nanoTime() + ClientSubmissionWindow.CONFIRMATION_MILLISECONDS * 1_000_000, activation)
    private fun intent(confirmation: GroupCapabilityConfirmation): GroupCapabilityIntent {
        check(confirmation.intent.actor == account && confirmation.activation == activation && confirmation.deadlineNanos - nanoTime() > 0 && confirmation.intent.confirmedUntilMilliseconds > now()) { "本次确认已过期，请刷新群状态后重新确认" }
        return confirmation.intent
    }
    suspend fun enqueue(confirmation: GroupCapabilityConfirmation) = mutex.withLock {
        val intent = intent(confirmation)
        val work = store.prepareCapability(intent, activation)
        confirmations[intent.operation] = confirmation.deadlineNanos
        work
    }
    suspend fun reconfirm(id: String, confirmation: GroupCapabilityConfirmation) = mutex.withLock {
        val old = store.capabilityWorks().first { it.intent.operation == id }
        val intent = intent(confirmation)
        require(old.intent.actor == account && old.intent.room == intent.room && old.status == GroupCapabilityStatus.DraftPaused && old.admission == null)
        val work = store.replaceCapabilityDraft(old, intent, activation)
        confirmations.remove(id); preparationEnds.remove(id); confirmations[intent.operation] = confirmation.deadlineNanos
        work
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = store.capabilityWorks().first { it.intent.operation == id }
        require(work.intent.actor == account && work.admission == null && !work.terminal)
        store.updateCapability(work, work.copy(status = GroupCapabilityStatus.DraftCancelled))
        confirmations.remove(id); preparationEnds.remove(id)
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.capabilityWorks().first { it.intent.operation == id }
        require(work.intent.actor == account && work.admission != null)
        if (!work.terminal) store.updateCapability(work, work.copy(status = GroupCapabilityStatus.Pending, executionStarted = commandExecutionStarted(work.executionStarted), attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.capabilityWorks();val candidatesObserved=System.nanoTime()
        for(work in candidates) {
            require(work.intent.actor == account)
            if (work.terminal || work.nextAttemptMilliseconds > now()) continue
            when(work.status) {
                GroupCapabilityStatus.DraftReady -> prepare(work)
                GroupCapabilityStatus.Pending -> execute(work,candidatesObserved)
                else -> Unit
            }
        }
    }
    private suspend fun prepare(saved: GroupCapabilityWork) {
        val id = saved.intent.operation; val deadline = confirmations[id]
        if (saved.activation != activation || deadline == null || deadline - nanoTime() <= 0 || saved.intent.confirmedUntilMilliseconds <= now() || saved.preparationAttempts >= 5) {
            store.updateCapability(saved, saved.copy(status = GroupCapabilityStatus.DraftPaused, reason = "confirmationRequired")); return
        }
        val end = preparationEnds.getOrPut(id) { minOf(deadline, nanoTime() + 60_000_000_000) }
        if (end - nanoTime() <= 0) { store.updateCapability(saved, saved.copy(status = GroupCapabilityStatus.DraftPaused, reason = "confirmationRequired")); return }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts + 1)
        store.updateCapability(saved, work)
        try {
            val result = withPreparationAttempt(work.preparationAttempts) {client.admit(work.intent)}
            if (end - nanoTime() <= 0 || work.intent.confirmedUntilMilliseconds <= now()) {
                store.updateCapability(work, work.copy(status = GroupCapabilityStatus.DraftPaused, reason = "confirmationRequired")); return
            }
            when(result) {
                is GroupCapabilityAdmissionResult.Admitted -> {
                    result.admission.validate(work.intent)
                    store.updateCapability(work, work.copy(executionStarted = false,admission = result.admission, status = GroupCapabilityStatus.Pending, nextAttemptMilliseconds = 0, reason = null))
                    confirmations.remove(id); preparationEnds.remove(id)
                    executionEnds[id] = nanoTime() + (result.admission.expiresAt - now()).coerceIn(0, 120_000) * 1_000_000
                }
                is GroupCapabilityAdmissionResult.Unavailable -> store.updateCapability(work, work.copy(status = GroupCapabilityStatus.DraftPaused, reason = result.reason))
                GroupCapabilityAdmissionResult.Conflict -> store.updateCapability(work, work.copy(status = GroupCapabilityStatus.DraftPaused, reason = "fingerprintConflict"))
                is GroupCapabilityAdmissionResult.Deferred -> deferPreparation(work, end, result.delayMilliseconds, false)
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            deferPreparation(work, end, 0, e is ClientFailure.Protocol || e is IllegalArgumentException)
            if (e is ClientFailure.SignedOut) throw e
        }
    }
    private suspend fun deferPreparation(work: GroupCapabilityWork, end: Long, floor: Long, malformed: Boolean) {
        val delay = maxOf(minOf(8_000, 1_000L shl work.preparationAttempts), floor)
        val next = Math.addExact(now(), delay)
        val paused = malformed || work.preparationAttempts >= 5 || end - nanoTime() <= delay * 1_000_000 || next >= work.intent.confirmedUntilMilliseconds
        store.updateCapability(work, work.copy(status = if (paused) GroupCapabilityStatus.DraftPaused else GroupCapabilityStatus.DraftReady,
            nextAttemptMilliseconds = next, reason = "confirmationRequired"))
    }
    private suspend fun execute(saved: GroupCapabilityWork,candidatesObserved:Long) {
        val command = saved.command(); val id = saved.intent.operation
        val remaining = (command.admission.expiresAt - now()).coerceIn(0, 120_000)
        val allowed = minOf(remaining, executionEnds[id]?.let { ((it - nanoTime()) / 1_000_000).coerceAtLeast(0) } ?: remaining)
        executionEnds[id] = nanoTime() + allowed * 1_000_000
        val close = allowed == 0L
        val recover = close || saved.reconcile || saved.executionStarted==null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true)
        if (work != saved) store.updateCapability(saved, work)
        val attempts = work.attempts + 1
        measureOperationStep(work.intent.action.operationKind(),if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            attempts,isRetry,candidatesObserved,
            observe={store.capabilityWork(work.intent.operation)?.takeIf {work.intent==it.intent && work.admission==it.admission}?.operationObservation(now())}) {
        try {
            val next = when (val result = withCommandAttempt(isRetry) {client.execute(command, recover, close)}) {
                is GroupCapabilityResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.rejection, attempts = attempts)
                GroupCapabilityResult.Unresolved -> work.copy(reconcile = close, attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                GroupCapabilityResult.Conflict -> work.copy(status = GroupCapabilityStatus.NeedsAttention, reason = "fingerprintConflict", attempts = attempts)
                is GroupCapabilityResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(5_000, result.delayMilliseconds))
            }
            store.updateCapability(work, if (!next.terminal && attempts >= 12) next.copy(status = GroupCapabilityStatus.NeedsAttention) else next)
            if (next.terminal) executionEnds.remove(id)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            store.updateCapability(work, work.copy(attempts = attempts, status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) GroupCapabilityStatus.NeedsAttention else GroupCapabilityStatus.Pending,
                nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
            if (e is ClientFailure.SignedOut) throw e
        }
        }
    }
}
