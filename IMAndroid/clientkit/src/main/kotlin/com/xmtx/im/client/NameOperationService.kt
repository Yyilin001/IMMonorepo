package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Fixed commands; bounded recovery rounds never replace the user's expected revision. */
class NameOperationService(private val actor: UserId,private val client: NameTransport,private val store: NameOperationStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    private val owner = UUID.randomUUID().toString().uppercase()
    /** Start a new account dispatcher only after cancelling and awaiting its previous owner. */
    suspend fun recoverAfterPreviousOwnerDrained() = mutex.withLock {
        (store as? NameOperationClaimStore)?.recoverNameClaimsAfterDrain(owner, now())
    }
    suspend fun refresh(target: NameTarget): NameSnapshot {
        val snapshot = client.snapshot(actor,target);require(snapshot.actor == actor && snapshot.target == target)
        currentCoroutineContext().ensureActive()
        return store.saveNameSnapshot(snapshot) ?: throw ClientFailure.Protocol()
    }
    suspend fun save(baseline: NameSnapshot,name: String?): NameWork = mutex.withLock {
        require(baseline.actor == actor)
        val time = now()
        val command = NameCommand(actor,baseline.target,UUID.randomUUID().toString().uppercase(),NameCommand.normalizedName(name),baseline.revision,
            Math.addExact(time,ClientSubmissionWindow.milliseconds(86_400_000)))
        if (store is NameOperationClaimStore) store.enqueueName(command, time) else store.enqueueName(command)
    }
    suspend fun retry(operation: String) = mutex.withLock {
        if (store is NameOperationClaimStore) { store.retryName(operation, now()); return@withLock }
        val work = store.nameWorks().first { it.command.operation == operation };require(work.command.actor == actor && work.status == NameStatus.NeedsAttention)
        store.updateName(work,work.copy(status = NameStatus.Pending,attempts = 0,roundStarted = null))
    }
    suspend fun discard(operation: String) = mutex.withLock {
        if (store is NameOperationClaimStore) { store.cancelOrCloseName(operation, now()); return@withLock }
        val work = store.nameWorks().first { it.command.operation == operation };require(work.command.actor == actor && !work.terminal)
        store.updateName(work,if(!work.submissionStarted) work.copy(status = NameStatus.Cancelled)
            else work.copy(closeRequested = true,reconcile = true,status = NameStatus.Pending,attempts = 0,roundStarted = null))
    }
    suspend fun flush() = mutex.withLock {
        if (store is NameOperationClaimStore) { DurableNameOperationRunner(actor, client, store, owner, now).flush(); return@withLock }
        val keys = mutableSetOf<NameTarget>();var count = 0
        val candidates=store.nameWorks();val candidatesObserved=System.nanoTime()
        for(saved in candidates) {
            require(saved.command.actor == actor)
            if(saved.terminal || !keys.add(saved.command.target) || saved.status != NameStatus.Pending || saved.nextAttempt > now()) continue
            if(count++ >= 4) break
            if(saved.attempts >= 5 || saved.roundStarted?.let { now()-it >= 60_000 } == true) {
                store.updateName(saved,saved.copy(status = NameStatus.NeedsAttention));continue
            }
            val close = saved.closeRequested || now() >= saved.command.deadline
            if(close && !saved.submissionStarted) {
                store.updateName(saved,saved.copy(status = NameStatus.Cancelled,reason = "expiredUnsubmitted"));continue
            }
            // Write uncertainty before issuing even the first byte. A restart must query this identity.
            val work = saved.copy(submissionStarted = true,reconcile = true,attempts = saved.attempts+1,roundStarted = saved.roundStarted ?: now())
            store.updateName(saved,work)
            measureOperationStep(if(saved.command.target is NameTarget.Contact) OperationKind.ContactAlias else OperationKind.GroupNickname,
                if(close || saved.reconcile) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                work.attempts,saved.submissionStarted,candidatesObserved,
                observe={store.nameWork(work.command.operation)?.takeIf {it.command==work.command}?.operationObservation(now())}) {
            try {
                val result = withTimeout(minOf(15_000L,60_000L-(now()-requireNotNull(work.roundStarted))).coerceAtLeast(1)) {
                    withCommandAttempt(saved.submissionStarted) {
                    if(close || saved.reconcile) client.recover(work.command,close) else client.submit(work.command)
                }
                }
                val next = when(result) {
                    is NameResult.Receipt -> work.copy(status = result.status,receipt = result.wire,reason = result.reason)
                    NameResult.Conflict -> work.copy(status = NameStatus.NeedsAttention,reason = "fingerprintConflict")
                    NameResult.Unresolved -> work.copy(reconcile = close,nextAttempt = Math.addExact(now(),5_000),reason = "unresolved")
                }
                store.updateName(work,if(!next.terminal && (next.attempts >= 5 || now()-requireNotNull(next.roundStarted) >= 60_000)) next.copy(status = NameStatus.NeedsAttention) else next)
            } catch(e: Exception) {
                if(e is CancellationException && e !is TimeoutCancellationException) throw e
                currentCoroutineContext().ensureActive()
                val failure = e as? ClientFailure.Http
                val hint = failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it,now()) }.getOrDefault(86_400_000) } ?: 0
                val delay = maxOf(hint,minOf(30_000L,1_000L shl work.attempts))
                val next = Math.addExact(now(),delay)
                val permanent = e is ClientFailure.Protocol || e is IllegalArgumentException || failure?.status in setOf(400,403,404,409,413,415,422)
                store.updateName(work,work.copy(status = if(permanent || work.attempts >= 5 || next-requireNotNull(work.roundStarted) >= 60_000) NameStatus.NeedsAttention else NameStatus.Pending,
                    nextAttempt = next,reason = "confirmationRequired"))
                if(e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
