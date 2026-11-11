package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

class MessageMutationService(private val actor: UserId, private val client: MessageMutationClient, private val store: MessageMutationStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    suspend fun enqueue(room: RoomId, message: MessageId, revision: Long, text: String?): MessageMutationWork = mutex.withLock {
        store.enqueueMutation(MessageMutationCommand(actor, room, message, UUID.randomUUID().toString().uppercase(), revision, text, Math.addExact(now(), 595_000)))
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.mutationWorks().first { it.command.operation == id }; require(work.command.actor == actor && work.status == MutationStatus.NeedsAttention)
        store.updateMutation(work, work.copy(status = MutationStatus.Pending, attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val visited = mutableSetOf<String>()
        val candidates=store.mutationWorks();val candidatesObserved=System.nanoTime()
        for(saved in candidates) {
            require(saved.command.actor == actor)
            if(saved.terminal || !visited.add(saved.command.orderingKey) || saved.status != MutationStatus.Pending || saved.nextAttempt > now()) continue
            val command = saved.command; val close = now() >= command.deadline
            val isRetry = commandExecutionStarted(saved.executionStarted)
            val work = saved.copy(reconcile = true, executionStarted = true)
            if(work != saved) store.updateMutation(saved, work)
            val attempts = work.attempts + 1
            measureOperationStep(if(command.text==null) OperationKind.WithdrawMessage else OperationKind.EditMessage,
                if(close || saved.reconcile || saved.executionStarted==null) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                attempts,isRetry,candidatesObserved,
                observe={store.mutationWork(command.operation)?.takeIf {it.command==command}?.operationObservation(now())}) {
            try {
                val next = when(val result = withCommandAttempt(isRetry) { client.execute(command, close || saved.reconcile || saved.executionStarted == null, close) }) {
                    is MutationResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.reason, attempts = attempts)
                    is MutationResult.Deferred -> work.copy(attempts = attempts, nextAttempt = now() + maxOf(5000, result.delayMilliseconds))
                    MutationResult.Unresolved -> work.copy(attempts = attempts, reconcile = close, nextAttempt = now() + 5000)
                    MutationResult.Conflict -> work.copy(status = MutationStatus.NeedsAttention, attempts = attempts, reason = "fingerprintConflict")
                }
                store.updateMutation(work, if(!next.terminal && attempts >= 12) next.copy(status = MutationStatus.NeedsAttention) else next)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                store.updateMutation(work, work.copy(attempts = attempts, nextAttempt = now() + minOf(60000, 1000L shl minOf(attempts,6)),
                    status = if(e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) MutationStatus.NeedsAttention else MutationStatus.Pending, reason = "confirmationRequired"))
                if(e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
