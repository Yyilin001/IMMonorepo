package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

class AccountPreferenceService(private val account: UserId, private val client: AccountPreferenceClient, private val store: AccountPreferenceStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime,
    private val commandNow: () -> Long = now) {
    private val activation = UUID.randomUUID().toString()
    private val confirmations = mutableMapOf<String, Long>()
    private val preparationEnds = mutableMapOf<String, Long>()
    private val executionEnds = mutableMapOf<String, Long>()
    private val mutex = Mutex()
    suspend fun baseline(kind: PreferenceKind): PreferenceSnapshot {
        val snapshot = client.baseline(kind); require(snapshot.actor == account); store.savePreference(snapshot)
        return store.preferenceSnapshots().first { it.value.kind == kind }
    }
    private fun draft(patch: PreferencePatch): PreferenceWork = PreferenceWork(account, UUID.randomUUID().toString().uppercase(), patch, activation,
        Math.addExact(now(), ClientSubmissionWindow.CONFIRMATION_MILLISECONDS))
    suspend fun enqueue(patch: PreferencePatch) = mutex.withLock {
        val work = draft(patch); val saved = store.preparePreference(work)
        confirmations[work.operation] = nanoTime() + 120_000_000_000; saved
    }
    suspend fun reconfirm(id: String) = mutex.withLock {
        val old = store.preferenceWorks().first { it.operation == id }
        require(old.actor == account && old.status == PreferenceStatus.DraftPaused && old.command == null)
        val replacement = draft(old.patch)
        val saved = store.replacePreferenceDraft(old, replacement)
        confirmations.remove(id); preparationEnds.remove(id); confirmations[saved.operation] = nanoTime() + 120_000_000_000; saved
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = store.preferenceWorks().first { it.operation == id }; require(work.actor == account && work.command == null && !work.terminal)
        store.updatePreference(work, work.copy(status = PreferenceStatus.DraftCancelled)); confirmations.remove(id); preparationEnds.remove(id)
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.preferenceWorks().first { it.operation == id }; require(work.actor == account && work.command != null)
        if(!work.terminal) store.updatePreference(work, work.copy(status = PreferenceStatus.Pending, executionStarted = commandExecutionStarted(work.executionStarted), attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.preferenceWorks();val candidatesObserved=System.nanoTime()
        for(work in candidates) {
            require(work.actor == account)
            if(work.terminal || work.nextAttemptMilliseconds > now()) continue
            when(work.status) { PreferenceStatus.DraftReady -> prepare(work); PreferenceStatus.Pending -> execute(work,candidatesObserved); else -> Unit }
        }
    }
    private suspend fun prepare(saved: PreferenceWork) {
        val id = saved.operation; val deadline = confirmations[id]
        if(saved.activation != activation || deadline == null || deadline - nanoTime() <= 5_000_000_000 || saved.confirmedUntil <= now() || saved.preparationAttempts >= 5) {
            store.updatePreference(saved, saved.copy(status = PreferenceStatus.DraftPaused, reason = "confirmationRequired")); return
        }
        val end = preparationEnds.getOrPut(id) { minOf(deadline, nanoTime() + 60_000_000_000) }
        if(end - nanoTime() <= 0) { store.updatePreference(saved, saved.copy(status = PreferenceStatus.DraftPaused, reason = "confirmationRequired")); return }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts + 1); store.updatePreference(saved, work)
        try {
            val snapshot = withPreparationAttempt(work.preparationAttempts) {client.baseline(work.patch.kind)}
            require(snapshot.actor == account && snapshot.value.kind == work.patch.kind)
            if(end - nanoTime() <= 0 || deadline - nanoTime() <= 5_000_000_000 || work.confirmedUntil <= now()) {
                store.updatePreference(work, work.copy(status = PreferenceStatus.DraftPaused, reason = "confirmationRequired")); return
            }
            val commandTime = commandNow()
            require(commandTime > 0)
            val remaining = ((deadline - nanoTime()) / 1_000_000 - 5000).coerceAtMost(115_000)
            check(remaining > 0)
            val commandDeadline = Math.addExact(commandTime, remaining)
            val command = PreferenceCommand(account, work.operation, work.patch.apply(snapshot.value), snapshot.revision, commandDeadline)
            store.savePreference(snapshot)
            store.updatePreference(work, work.copy(executionStarted = false,command = command, status = PreferenceStatus.Pending, nextAttemptMilliseconds = 0, reason = null))
            confirmations.remove(id); preparationEnds.remove(id)
            executionEnds[id] = deadline - 5_000_000_000
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            val delay = maxOf(minOf(8000, 1000L shl work.preparationAttempts), (e as? PreferenceBackpressure)?.delayMilliseconds ?: 0)
            val next = Math.addExact(now(), delay)
            val paused = e is ClientFailure.Protocol || e is IllegalArgumentException || work.preparationAttempts >= 5 || end - nanoTime() <= delay * 1_000_000 || next >= work.confirmedUntil
            store.updatePreference(work, work.copy(status = if(paused) PreferenceStatus.DraftPaused else PreferenceStatus.DraftReady, nextAttemptMilliseconds = next, reason = "confirmationRequired"))
            if(e is ClientFailure.SignedOut) throw e
        }
    }
    private suspend fun execute(saved: PreferenceWork,candidatesObserved:Long) {
        val command = requireNotNull(saved.command); val id = saved.operation
        // The wire deadline is server time; the persisted admission fence remains device-local.
        val remaining = (saved.confirmedUntil - now()).coerceIn(0, 120_000)
        val allowed = minOf(remaining, executionEnds[id]?.let { ((it - nanoTime()) / 1_000_000).coerceAtLeast(0) } ?: remaining)
        executionEnds[id] = nanoTime() + allowed * 1_000_000
        val close = allowed == 0L
        val recover = close || saved.reconcile || saved.executionStarted==null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true)
        if (work != saved) store.updatePreference(saved, work)
        val attempts = work.attempts + 1
        measureOperationStep(command.value.kind.operationKind(),if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            attempts,isRetry,candidatesObserved,
            observe={store.preferenceWork(work.operation)?.takeIf {work.command==it.command}?.operationObservation(now())}) {
        try {
            val next = when (val result = withCommandAttempt(isRetry) {client.execute(command, recover, close)}) {
                is PreferenceResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.rejection, attempts = attempts)
                PreferenceResult.Unresolved -> work.copy(reconcile = close, attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                PreferenceResult.Conflict -> work.copy(status = PreferenceStatus.NeedsAttention, reason = "fingerprintConflict", attempts = attempts)
                is PreferenceResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(5_000, result.delayMilliseconds))
            }
            store.updatePreference(work, if (!next.terminal && attempts >= 12) next.copy(status = PreferenceStatus.NeedsAttention) else next)
            if (next.terminal) executionEnds.remove(id)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            store.updatePreference(work, work.copy(attempts = attempts, status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) PreferenceStatus.NeedsAttention else PreferenceStatus.Pending,
                nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
            if (e is ClientFailure.SignedOut) throw e
        }
        }
    }
}
