package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

class ForwardPlanService(private val actor: UserId, private val client: ForwardPlanClient, private val store: ForwardPlanStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    suspend fun enqueue(sources: PersistentList<ForwardSource>, targets: PersistentList<RoomId>) = mutex.withLock {
        store.enqueueForward(ForwardCommand(actor, UUID.randomUUID().toString().uppercase(), sources, targets, Math.addExact(now(), 595000)))
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.forwardWorks().first { it.command.operation == id }; require(work.command.actor == actor && work.status == ForwardStatus.NeedsAttention)
        store.updateForward(work, work.copy(status = ForwardStatus.Pending, attempts = 0, reason = null))
    }
    suspend fun cancel(id: String) = mutex.withLock {
        val work = store.forwardWorks().first { it.command.operation == id }; require(work.command.actor == actor)
        if(!work.terminal) store.updateForward(work, work.copy(cancelRequested = true, status = if(work.submissionStarted) ForwardStatus.Pending else ForwardStatus.Cancelled,
            reconcile = work.submissionStarted, attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.forwardWorks();val candidatesObserved=System.nanoTime()
        for(saved in candidates) {
            require(saved.command.actor == actor)
            if(saved.terminal || saved.status != ForwardStatus.Pending || saved.nextAttempt > now()) continue
            val command = saved.command; val close = now() >= command.deadline
            if(close && !saved.submissionStarted) { store.updateForward(saved, saved.copy(status = ForwardStatus.Expired)); continue }
            val recovery = when { saved.cancelRequested -> "cancelRemaining"; close -> "closeIfUnstarted"; saved.reconcile || saved.progress != null -> "query"; else -> null }
            val work = saved.copy(submissionStarted = true, reconcile = true)
            if(work != saved) store.updateForward(saved, work)
            val attempts = work.attempts + 1
            measureOperationStep(OperationKind.ForwardMessage,
                if(recovery!=null) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                attempts,saved.submissionStarted,candidatesObserved,
                observe={store.forwardWork(work.command.operation)?.takeIf {it.command==work.command}?.operationObservation(now())}) {
            try {
                val next = when(val result = withCommandAttempt(saved.submissionStarted) { client.execute(command, recovery) }) {
                    is ForwardResult.Receipt -> work.copy(status = result.status, progress = result.progress, receipt = result.wire, attempts = attempts)
                    is ForwardResult.Processing -> work.copy(progress = result.progress, attempts = attempts, nextAttempt = now() + 5000)
                    is ForwardResult.Deferred -> work.copy(attempts = attempts, nextAttempt = now() + maxOf(5000, result.delay))
                    ForwardResult.Unresolved -> work.copy(reconcile = saved.progress != null || close || saved.cancelRequested, attempts = attempts, nextAttempt = now() + 5000)
                    ForwardResult.Conflict -> work.copy(status = ForwardStatus.NeedsAttention, reason = "fingerprintConflict", attempts = attempts)
                }
                store.updateForward(work, if(!next.terminal && attempts >= 12) next.copy(status = ForwardStatus.NeedsAttention) else next)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                store.updateForward(work, work.copy(attempts = attempts, nextAttempt = now() + minOf(60000, 1000L shl minOf(attempts,6)),
                    status = if(e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) ForwardStatus.NeedsAttention else ForwardStatus.Pending, reason = "confirmationRequired"))
                if(e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
