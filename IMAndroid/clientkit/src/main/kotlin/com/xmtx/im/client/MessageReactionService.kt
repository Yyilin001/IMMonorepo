package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

class MessageReactionService(private val actor: UserId, private val client: MessageReactionClient, private val store: MessageReactionStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    suspend fun enqueue(room: RoomId, message: MessageId, reaction: String, present: Boolean): ReactionWork = mutex.withLock {
        // Swift currently shares the send deadline helper (10 minutes less clock-skew margin).
        store.enqueueReaction(ReactionIntent(actor, room, message, UUID.randomUUID().toString().uppercase(), normalizedReaction(reaction), present, Math.addExact(now(), 595_000)))
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.reactionWorks().first { it.intent.operation == id }; require(work.intent.actor == actor)
        require(work.status in setOf(ReactionStatus.PreparationPaused, ReactionStatus.NeedsAttention))
        store.updateReaction(work, work.copy(status = if(work.command == null) ReactionStatus.Draft else ReactionStatus.Pending,
            executionStarted = if(work.command==null) false else commandExecutionStarted(work.executionStarted), attempts = 0, preparationAttempts = 0, preparationStarted = null, reason = null))
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = store.reactionWorks().first { it.intent.operation == id }; require(work.intent.actor == actor && work.command == null && !work.terminal)
        store.updateReaction(work, work.copy(status = ReactionStatus.Cancelled))
    }
    suspend fun flush() = mutex.withLock {
        val visited = mutableSetOf<String>()
        val candidates=store.reactionWorks();val candidatesObserved=System.nanoTime()
        for(work in candidates) {
            require(work.intent.actor == actor)
            if(work.terminal || !visited.add(work.intent.orderingKey) || work.nextAttempt > now()) continue
            when(work.status) { ReactionStatus.Draft -> prepare(work); ReactionStatus.Pending -> execute(work,candidatesObserved); else -> Unit }
        }
    }
    private suspend fun prepare(saved: ReactionWork) {
        if(now() >= saved.intent.deadline) { store.updateReaction(saved, saved.copy(status = ReactionStatus.Expired)); return }
        if(saved.preparationAttempts >= 5 || saved.preparationStarted?.let { now() - it >= 60000 } == true) {
            store.updateReaction(saved, saved.copy(status = ReactionStatus.PreparationPaused, reason = "baselineRequired")); return
        }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts + 1, preparationStarted = saved.preparationStarted ?: now())
        store.updateReaction(saved, work)
        try {
            val baseline = withPreparationAttempt(work.preparationAttempts) {client.baseline(work.intent)}
            val next = when {
                now() >= work.intent.deadline -> work.copy(status = ReactionStatus.Expired)
                now() - requireNotNull(work.preparationStarted) >= 60000 -> work.copy(status = ReactionStatus.PreparationPaused, reason = "baselineRequired")
                else -> work.copy(executionStarted = false,command = ReactionCommand(work.intent, baseline.revision), status = ReactionStatus.Pending, nextAttempt = 0, reason = null)
            }
            store.updateReaction(work, next)
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            val delay = maxOf(minOf(8000, 1000L shl work.preparationAttempts), (e as? ReactionBackpressure)?.delayMilliseconds ?: 0)
            val next = Math.addExact(now(), delay)
            val paused = e is ClientFailure.Protocol || e is IllegalArgumentException || work.preparationAttempts >= 5 || next - requireNotNull(work.preparationStarted) >= 60000
            store.updateReaction(work, work.copy(status = if(paused) ReactionStatus.PreparationPaused else ReactionStatus.Draft, nextAttempt = next, reason = "baselineRequired"))
            if(e is ClientFailure.SignedOut) throw e
        }
    }
    private suspend fun execute(saved: ReactionWork,candidatesObserved:Long) {
        val command = requireNotNull(saved.command); val close = now() >= command.intent.deadline
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true)
        if(work != saved) store.updateReaction(saved, work)
        val attempts = work.attempts + 1
        val recover=close || saved.reconcile || saved.executionStarted==null
        measureOperationStep(OperationKind.Reaction,if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            attempts,isRetry,candidatesObserved,
            observe={store.reactionWork(work.intent.operation)?.takeIf {it.command==command && it.intent==work.intent}?.operationObservation(now())}) {
        try {
            val next = when(val result = withCommandAttempt(isRetry) {client.execute(command, recover, close)}) {
                is ReactionResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.reason, attempts = attempts)
                is ReactionResult.Deferred -> work.copy(attempts = attempts, nextAttempt = now() + maxOf(5000, result.delayMilliseconds))
                ReactionResult.Unresolved -> work.copy(attempts = attempts, reconcile = close, nextAttempt = now() + 5000)
                ReactionResult.Conflict -> work.copy(status = ReactionStatus.NeedsAttention, attempts = attempts, reason = "fingerprintConflict")
            }
            store.updateReaction(work, if(!next.terminal && attempts >= 12) next.copy(status = ReactionStatus.NeedsAttention) else next)
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            store.updateReaction(work, work.copy(attempts = attempts, nextAttempt = now() + minOf(60000, 1000L shl minOf(attempts,6)),
                status = if(e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) ReactionStatus.NeedsAttention else ReactionStatus.Pending, reason = "confirmationRequired"))
            if(e is ClientFailure.SignedOut) throw e
        }
        }
    }
}
