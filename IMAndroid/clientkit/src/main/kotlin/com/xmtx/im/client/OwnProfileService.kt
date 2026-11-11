package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Account-owned fixed intents. Unknown outcomes always resume the original operation. */
class OwnProfileService(private val actor: UserId,private val client: OwnProfileTransport,private val store: OwnProfileStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    private val owner = UUID.randomUUID().toString().uppercase()
    suspend fun recoverAfterPreviousOwnerDrained() = mutex.withLock {
        (store as? OwnProfileOperationClaimStore)?.recoverOwnProfileClaimsAfterDrain(owner,now())
    }
    private suspend fun enqueue(command: OwnProfileCommand, replaces: String? = null): OwnProfileWork =
        if (store is OwnProfileOperationClaimStore) store.enqueueOwnProfile(command,replaces,now()) else store.enqueueOwnProfile(command,replaces)
    suspend fun refresh(): ProfileView {
        val value = client.current();require(value.user == actor);currentCoroutineContext().ensureActive()
        return store.saveOwnProfile(value) ?: throw ClientFailure.Protocol()
    }
    suspend fun save(baseline: ProfileView,patch: OwnProfilePatch) = mutex.withLock {
        require(baseline.user == actor && baseline.state == ProfileState.Active)
        enqueue(command(baseline.revision,patch))
    }
    private fun command(revision: Long,patch: OwnProfilePatch) = OwnProfileCommand(actor,UUID.randomUUID().toString().uppercase(),revision,patch,Math.addExact(now(),86_400_000))
    suspend fun retry(operation: String) = mutex.withLock {
        if (store is OwnProfileOperationClaimStore) { store.retryOwnProfile(operation,now()); return@withLock }
        val work = store.ownProfileWorks().first { it.command.operation == operation };require(work.command.actor == actor && work.status == OwnProfileStatus.NeedsAttention)
        store.updateOwnProfile(work,work.copy(status = OwnProfileStatus.Pending,attempts = 0,roundStarted = null))
    }
    /** Explicit reapplication creates a new identity only after the original outcome is terminal. */
    suspend fun reapply(operation: String) = mutex.withLock {
        val work = store.ownProfileWorks().first { it.command.operation == operation }
        require(work.command.actor == actor && work.terminal && work.draftRetained && work.status != OwnProfileStatus.Committed)
        val latest = refresh();require(latest.state == ProfileState.Active)
        enqueue(command(latest.revision,work.command.patch),replaces = operation)
    }
    suspend fun discardDraft(operation: String) = mutex.withLock { store.discardOwnProfileDraft(operation) }
    suspend fun flush() = mutex.withLock {
        if (store is OwnProfileOperationClaimStore) { DurableOwnProfileOperationRunner(actor,client,store,owner,now).flush(); return@withLock }
        val saved = store.ownProfileWorks().firstOrNull { !it.terminal } ?: return@withLock
        val candidatesObserved=System.nanoTime()
        require(saved.command.actor == actor)
        if(saved.status != OwnProfileStatus.Pending || saved.nextAttempt > now()) return@withLock
        if(saved.attempts >= 5 || saved.roundStarted?.let { now()-it >= 60_000 } == true) {
            store.updateOwnProfile(saved,saved.copy(status = OwnProfileStatus.NeedsAttention));return@withLock
        }
        val close = now() >= saved.command.deadline
        if(close && !saved.submissionStarted) { store.updateOwnProfile(saved,saved.copy(status = OwnProfileStatus.Expired,reason = "expiredUnsubmitted"));return@withLock }
        val work = saved.copy(submissionStarted = true,reconcile = true,attempts = saved.attempts+1,roundStarted = saved.roundStarted ?: now())
        store.updateOwnProfile(saved,work)
        measureOperationStep(OperationKind.ProfileUpdate,
            if(close || saved.reconcile) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            work.attempts,saved.submissionStarted,candidatesObserved,
            observe={store.ownProfileWork(work.command.operation)?.takeIf {it.command==work.command}?.operationObservation(now())}) {
        try {
            val result = withTimeout(minOf(15_000L,60_000L-(now()-requireNotNull(work.roundStarted))).coerceAtLeast(1)) {
                withCommandAttempt(saved.submissionStarted) {
                    if(close || saved.reconcile) client.recover(work.command,close) else client.submit(work.command)
                }
            }
            val next = when(result) {
                is OwnProfileResult.Receipt -> work.copy(status = result.status,receipt = result.wire,reason = result.reason,draftRetained = result.status != OwnProfileStatus.Committed)
                OwnProfileResult.Unresolved -> work.copy(reconcile = close,nextAttempt = Math.addExact(now(),5_000),reason = "unresolved")
                OwnProfileResult.Conflict -> work.copy(status = OwnProfileStatus.NeedsAttention,reason = "fingerprintConflict")
            }
            store.updateOwnProfile(work,if(!next.terminal && (next.attempts >= 5 || now()-requireNotNull(next.roundStarted) >= 60_000)) next.copy(status = OwnProfileStatus.NeedsAttention) else next)
        } catch(e: Exception) {
            if(e is CancellationException && e !is TimeoutCancellationException) throw e
            currentCoroutineContext().ensureActive()
            val failure = e as? ClientFailure.Http
            val hint = failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it,now()) }.getOrDefault(86_400_000) } ?: 0
            val next = Math.addExact(now(),maxOf(hint,minOf(30_000L,1_000L shl work.attempts)))
            val permanent = e is ClientFailure.Protocol || e is IllegalArgumentException || failure?.status in setOf(400,403,404,409,413,415,422)
            store.updateOwnProfile(work,work.copy(status = if(permanent || work.attempts >= 5 || next-requireNotNull(work.roundStarted) >= 60_000) OwnProfileStatus.NeedsAttention else OwnProfileStatus.Pending,
                nextAttempt = next,reason = "confirmationRequired"))
            if(e is ClientFailure.SignedOut) throw e
        }
        }
    }
}
