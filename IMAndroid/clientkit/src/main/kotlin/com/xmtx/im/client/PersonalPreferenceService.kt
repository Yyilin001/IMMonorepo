package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Per-key ordered commands. Uncertain submissions are recovered before any replay. */
class PersonalPreferenceService(private val account: UserId, private val client: PersonalPreferenceClient, private val store: PersonalPreferenceStore,
    private val now: () -> Long = System::currentTimeMillis) {
    private val mutex = Mutex()
    suspend fun conversation(room: RoomId, patch: ConversationPatch) = mutex.withLock { store.enqueueConversation(room, patch, now()) }
    suspend fun favorite(room: RoomId, message: MessageId, value: Boolean) = mutex.withLock { store.enqueueFavorite(room, message, value, now()) }
    suspend fun retry(id: String) = mutex.withLock {
        val work = store.personalWorks().first { it.operation == id }; require(work.actor == account && work.status == PersonalStatus.NeedsAttention)
        store.updatePersonal(work, work.copy(status = PersonalStatus.Pending, attempts = 0))
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = store.personalWorks().first { it.operation == id }; require(work.actor == account && !work.submissionStarted && !work.terminal)
        store.updatePersonal(work, work.copy(status = PersonalStatus.Cancelled))
    }
    suspend fun flush() = mutex.withLock {
        store.preparePersonal(now())
        val visited = mutableSetOf<String>()
        val candidates=store.personalWorks();val candidatesObserved=System.nanoTime()
        for(saved in candidates) {
            require(saved.actor == account)
            if(saved.terminal || !visited.add(saved.target.key) || saved.status != PersonalStatus.Pending || saved.nextAttempt > now()) continue
            val command = requireNotNull(saved.command)
            val close = now() >= command.deadline
            val work = saved.copy(submissionStarted = true, reconcile = true)
            if(work != saved) store.updatePersonal(saved, work)
            val attempts = work.attempts + 1
            measureOperationStep(if(saved.target is PersonalTarget.Conversation) OperationKind.ConversationPreference else OperationKind.MessageFavorite,
                if(close || saved.reconcile) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                attempts,saved.submissionStarted,candidatesObserved,
                observe={store.personalWork(work.operation)?.takeIf {it.command==work.command}?.operationObservation(now())}) {
            try {
                val result = withCommandAttempt(saved.submissionStarted) {
                    if(close || saved.reconcile) client.recover(command, close) else client.submit(command)
                }
                val next = when(result) {
                    is PersonalResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.reason, attempts = attempts)
                    PersonalResult.Unresolved -> work.copy(reconcile = close, attempts = attempts, nextAttempt = now() + 5000)
                    PersonalResult.Conflict -> work.copy(status = PersonalStatus.NeedsAttention, reason = "fingerprintConflict", attempts = attempts)
                }
                store.updatePersonal(work, if(!next.terminal && attempts >= 12) next.copy(status = PersonalStatus.NeedsAttention) else next)
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                val gateway = e as? GatewayFailure
                val floor = maxOf((e as? PersonalBackpressure)?.delayMilliseconds ?: 0, (gateway?.retryAfterSeconds?.toLong() ?: 0).coerceAtLeast(0) * 1000)
                val permanent = e is ClientFailure.Protocol || e is IllegalArgumentException || gateway?.retryable == false ||
                    e is ClientFailure.Http && e.status in setOf(400,403,404,409,413,415,422)
                store.updatePersonal(work, work.copy(status = if(permanent || attempts >= 12) PersonalStatus.NeedsAttention else PersonalStatus.Pending,
                    attempts = attempts, nextAttempt = Math.addExact(now(), maxOf(floor, minOf(60_000, 1000L shl minOf(attempts,6)))), reason = "confirmationRequired"))
                if(e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
