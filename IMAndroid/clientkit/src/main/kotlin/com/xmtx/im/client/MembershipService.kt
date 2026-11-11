package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Memory-only authority for one click. Reopening an app never resurrects an unadmitted draft's confirmation. */
data class MembershipConfirmation(val room: RoomId, val action: MembershipAction, val revision: Long, val operation: String,
    val confirmedUntilMilliseconds: Long, val deadlineNanos: Long, val activation: String)
class MembershipService(private val account: UserId, private val client: MembershipClient, private val store: MembershipStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime) {
    private val activation = UUID.randomUUID().toString()
    private val confirmations = mutableMapOf<String, Long>()
    private val preparationEnds = mutableMapOf<String, Long>()
    private val executionEnds = mutableMapOf<String, Long>()
    private val mutex = Mutex()
    fun confirmation(room: RoomId, action: MembershipAction, revision: Long): MembershipConfirmation {
        require(revision in 0 until Long.MAX_VALUE)
        return MembershipConfirmation(room, action, revision, UUID.randomUUID().toString().uppercase(), Math.addExact(now(), 115_000), nanoTime() + 115_000_000_000, activation)
    }
    private fun intent(target: UserId, confirmation: MembershipConfirmation): MembershipIntent {
        check(confirmation.activation == activation && confirmation.deadlineNanos - nanoTime() > 0 && confirmation.confirmedUntilMilliseconds > now()) { "本次确认已过期，请刷新成员后重新确认" }
        return MembershipIntent(account, confirmation.room, confirmation.operation, target, confirmation.action, confirmation.revision, confirmation.confirmedUntilMilliseconds)
    }
    suspend fun enqueue(target: UserId, confirmation: MembershipConfirmation) = mutex.withLock {
        val intent = intent(target, confirmation)
        val work = store.prepareMembership(intent, activation)
        confirmations[intent.operation] = confirmation.deadlineNanos
        work
    }
    suspend fun reconfirm(id: String, confirmation: MembershipConfirmation) = mutex.withLock {
        val old = store.membershipWorks().first { it.intent.operation == id }
        require(old.intent.actor == account && old.intent.room == confirmation.room && old.intent.action == confirmation.action && old.status == MembershipStatus.DraftPaused && old.admission == null)
        val intent = intent(old.intent.target, confirmation)
        val work = store.replaceMembershipDraft(old, intent, activation)
        confirmations.remove(id); preparationEnds.remove(id); confirmations[intent.operation] = confirmation.deadlineNanos
        work
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = store.membershipWorks().first { it.intent.operation == id }
        require(work.intent.actor == account && work.admission == null && !work.terminal)
        store.updateMembership(work, work.copy(status = MembershipStatus.DraftCancelled))
        confirmations.remove(id); preparationEnds.remove(id)
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.membershipWorks().first { it.intent.operation == id }
        require(work.intent.actor == account && work.admission != null)
        if (!work.terminal) store.updateMembership(work, work.copy(status = MembershipStatus.Pending, executionStarted = commandExecutionStarted(work.executionStarted), attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.membershipWorks();val candidatesObserved=System.nanoTime()
        for(work in candidates) {
            require(work.intent.actor == account)
            if (work.terminal || work.nextAttemptMilliseconds > now()) continue
            when(work.status) {
                MembershipStatus.DraftReady -> prepare(work)
                MembershipStatus.Pending -> execute(work,candidatesObserved)
                else -> Unit
            }
        }
    }
    private suspend fun prepare(saved: MembershipWork) {
        val id = saved.intent.operation; val deadline = confirmations[id]
        if (saved.activation != activation || deadline == null || deadline - nanoTime() <= 0 || saved.intent.confirmedUntilMilliseconds <= now() || saved.preparationAttempts >= 5) {
            store.updateMembership(saved, saved.copy(status = MembershipStatus.DraftPaused, reason = "confirmationRequired")); return
        }
        val end = preparationEnds.getOrPut(id) { minOf(deadline, nanoTime() + 60_000_000_000) }
        if (end - nanoTime() <= 0) { store.updateMembership(saved, saved.copy(status = MembershipStatus.DraftPaused, reason = "confirmationRequired")); return }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts + 1)
        store.updateMembership(saved, work)
        try {
            val result = withPreparationAttempt(work.preparationAttempts) {client.admit(work.intent)}
            if (end - nanoTime() <= 0 || work.intent.confirmedUntilMilliseconds <= now()) {
                store.updateMembership(work, work.copy(status = MembershipStatus.DraftPaused, reason = "confirmationRequired")); return
            }
            when(result) {
                is MembershipAdmissionResult.Admitted -> {
                    result.admission.validate(work.intent)
                    store.updateMembership(work, work.copy(executionStarted = false,admission = result.admission, status = MembershipStatus.Pending, nextAttemptMilliseconds = 0, reason = null))
                    confirmations.remove(id); preparationEnds.remove(id)
                    executionEnds[id] = nanoTime() + (result.admission.expiresAt - now()).coerceIn(0, 120_000) * 1_000_000
                }
                is MembershipAdmissionResult.Unavailable -> store.updateMembership(work, work.copy(status = MembershipStatus.DraftPaused, reason = result.reason))
                MembershipAdmissionResult.Conflict -> store.updateMembership(work, work.copy(status = MembershipStatus.DraftPaused, reason = "fingerprintConflict"))
                is MembershipAdmissionResult.Deferred -> deferPreparation(work, end, result.delayMilliseconds, false)
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            deferPreparation(work, end, 0, e is ClientFailure.Protocol || e is IllegalArgumentException)
            if (e is ClientFailure.SignedOut) throw e
        }
    }
    private suspend fun deferPreparation(work: MembershipWork, end: Long, floor: Long, malformed: Boolean) {
        val delay = maxOf(minOf(8_000, 1_000L shl work.preparationAttempts), floor)
        val next = Math.addExact(now(), delay)
        val paused = malformed || work.preparationAttempts >= 5 || end - nanoTime() <= delay * 1_000_000 || next >= work.intent.confirmedUntilMilliseconds
        store.updateMembership(work, work.copy(status = if (paused) MembershipStatus.DraftPaused else MembershipStatus.DraftReady,
            nextAttemptMilliseconds = next, reason = "confirmationRequired"))
    }
    private suspend fun execute(saved: MembershipWork,candidatesObserved:Long) {
        val command = saved.command(); val id = saved.intent.operation
        val remaining = (command.admission.expiresAt - now()).coerceIn(0, 120_000)
        val allowed = minOf(remaining, executionEnds[id]?.let { ((it - nanoTime()) / 1_000_000).coerceAtLeast(0) } ?: remaining)
        executionEnds[id] = nanoTime() + allowed * 1_000_000
        val close = allowed == 0L
        val recover = close || saved.reconcile || saved.executionStarted==null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true)
        if (work != saved) store.updateMembership(saved, work)
        val attempts = work.attempts + 1
        measureOperationStep(OperationKind.Membership,if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            attempts,isRetry,candidatesObserved,
            observe={store.membershipWork(work.intent.operation)?.takeIf {work.intent==it.intent && work.admission==it.admission}?.operationObservation(now())}) {
        try {
            val next = when (val result = withCommandAttempt(isRetry) {client.execute(command, recover, close)}) {
                is MembershipResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.rejection, attempts = attempts)
                MembershipResult.Unresolved -> work.copy(reconcile = close, attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                MembershipResult.Conflict -> work.copy(status = MembershipStatus.NeedsAttention, reason = "fingerprintConflict", attempts = attempts)
                is MembershipResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(5_000, result.delayMilliseconds))
            }
            store.updateMembership(work, if (!next.terminal && attempts >= 12) next.copy(status = MembershipStatus.NeedsAttention) else next)
            if (next.terminal) executionEnds.remove(id)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            store.updateMembership(work, work.copy(attempts = attempts, status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) MembershipStatus.NeedsAttention else MembershipStatus.Pending,
                nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
            if (e is ClientFailure.SignedOut) throw e
        }
        }
    }
}
