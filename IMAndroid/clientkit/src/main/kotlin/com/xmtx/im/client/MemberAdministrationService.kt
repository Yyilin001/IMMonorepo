package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

data class AdministrationConfirmation(val intent: AdministrationIntent,val activation: String,val deadlineNanos: Long)
/** Separate draft authority and frozen command recovery, matching the member-administration contract. */
class AdministrationService(private val actor: UserId,private val client: AdministrationClient,private val store: AdministrationStore,
    private val now: () -> Long = System::currentTimeMillis,private val mono: () -> Long = System::nanoTime) {
    private val activation = UUID.randomUUID().toString()
    private val confirmations = mutableMapOf<String,Long>()
    private val preparationEnds = mutableMapOf<String,Long>()
    private val submissionEnds = mutableMapOf<String,Long>()
    private val roundEnds = mutableMapOf<String,Long>()
    private val mutex = Mutex()
    fun confirmation(room: RoomId,target: UserId,action: AdministrationAction,reason: String,revision: Long): AdministrationConfirmation {
        if(action is AdministrationAction.Mute) require(action.until > now())
        return AdministrationConfirmation(AdministrationIntent(actor,room,UUID.randomUUID().toString().uppercase(),target,action,moderationReason(reason),revision,Math.addExact(now(),115000)),activation,mono()+115000000000)
    }
    private fun validate(value: AdministrationConfirmation) {
        require(value.activation == activation && value.intent.actor == actor && value.deadlineNanos > mono() && value.intent.deadline > now() && value.intent.deadline-now() <= 120000 && value.deadlineNanos-mono() <= 120000000000) { "请刷新成员后重新确认" }
        (value.intent.action as? AdministrationAction.Mute)?.let { require(it.until > now()) { "禁言期限已过，请重新选择时长" } }
    }
    suspend fun enqueue(value: AdministrationConfirmation) = mutex.withLock {
        validate(value);store.prepareAdministration(value.intent,activation).also { confirmations[value.intent.key] = value.deadlineNanos }
    }
    suspend fun reconfirm(id: String,value: AdministrationConfirmation) = mutex.withLock {
        validate(value);val old = owned(id)
        require(old.status == AdministrationStatus.DraftPaused && old.intent.room == value.intent.room && old.intent.target == value.intent.target && old.intent.action == value.intent.action && old.intent.reason == value.intent.reason)
        store.replaceAdministrationDraft(old,value.intent,activation).also { confirmations.remove(id);preparationEnds.remove(id);confirmations[value.intent.key] = value.deadlineNanos }
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = owned(id);require(work.draft && !work.terminal && work.admission == null)
        store.updateAdministration(work,work.copy(status = AdministrationStatus.DraftCancelled));confirmations.remove(id);preparationEnds.remove(id)
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = owned(id);require(!work.draft && !work.terminal)
        store.updateAdministration(work,work.copy(status = AdministrationStatus.Pending,executionStarted = commandExecutionStarted(work.executionStarted), attempts = 0,roundEnd = now()+60000));roundEnds[id] = mono()+60000000000
    }
    private suspend fun owned(id: String) = store.administrationWorks().first { it.intent.key == id }.also { require(it.intent.actor == actor) }
    suspend fun flush() = mutex.withLock {
        val candidates = store.administrationWorks(); val candidatesObserved = System.nanoTime()
        for(work in candidates) {
            require(work.intent.actor == actor)
            when(work.status) {
                AdministrationStatus.DraftReady -> if(work.nextAttempt <= now() || work.activation != activation) prepare(work)
                AdministrationStatus.Pending -> execute(work, candidatesObserved)
                else -> Unit
            }
        }
    }
    private suspend fun prepare(saved: AdministrationWork) {
        val id = saved.intent.key;val confirmation = confirmations[id]
        val end = preparationEnds.getOrPut(id) { minOf(confirmation ?: mono(),mono() + (if(saved.preparationEnd > 0) saved.preparationEnd-now() else 60000).coerceIn(0,60000)*1000000) }
        if(saved.activation != activation || confirmation == null || end <= mono() || saved.intent.deadline <= now() || saved.preparationAttempts >= 5) {
            store.updateAdministration(saved,saved.copy(status = AdministrationStatus.DraftPaused,reason = "confirmationRequired"));return
        }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts+1,preparationEnd = if(saved.preparationEnd > 0) saved.preparationEnd else minOf(now()+60000,saved.intent.deadline))
        store.updateAdministration(saved,work)
        try {
            val result = withTimeout(minOf(15000,((end-mono())/1000000).coerceAtLeast(1))) { withPreparationAttempt(work.preparationAttempts) {client.admit(work.intent)} }
            if(end <= mono() || work.intent.deadline <= now()) { store.updateAdministration(work,work.copy(status = AdministrationStatus.DraftPaused,reason = "confirmationRequired"));return }
            when(result) {
                is AdministrationAdmissionResult.Admitted -> {
                    store.updateAdministration(work,work.copy(executionStarted = false,status = AdministrationStatus.Pending,admission = result.value,nextAttempt = 0,roundEnd = now()+60000,reason = null))
                    submissionEnds[id] = minOf(confirmation,mono()+(result.value.expires-now()).coerceIn(0,120000)*1000000)
                    roundEnds[id] = mono()+60000000000;confirmations.remove(id);preparationEnds.remove(id)
                }
                is AdministrationAdmissionResult.Unavailable -> store.updateAdministration(work,work.copy(status = AdministrationStatus.DraftPaused,reason = result.reason))
                AdministrationAdmissionResult.Conflict -> store.updateAdministration(work,work.copy(status = AdministrationStatus.DraftPaused,reason = "fingerprintConflict"))
            }
        } catch(e: TimeoutCancellationException) { deferPreparation(work,end,0,false) }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) { deferPreparation(work,end,(e as? AdministrationBackpressure)?.delay ?: 0,e is IllegalArgumentException || e is ClientFailure.Protocol);if(e is ClientFailure.SignedOut) throw e }
    }
    private suspend fun deferPreparation(work: AdministrationWork,end: Long,floor: Long,stop: Boolean) {
        val delay = maxOf(minOf(8000,1000L shl work.preparationAttempts),floor);val next = Math.addExact(now(),delay)
        val pause = stop || work.preparationAttempts >= 5 || end-mono() <= delay*1000000 || next >= work.intent.deadline
        store.updateAdministration(work,work.copy(status = if(pause) AdministrationStatus.DraftPaused else AdministrationStatus.DraftReady,nextAttempt = next,reason = "confirmationRequired"))
    }
    private suspend fun execute(saved: AdministrationWork, candidatesObserved: Long) {
        val id = saved.intent.key;val command = saved.command()
        val round = roundEnds.getOrPut(id) { mono()+(saved.roundEnd-now()).coerceIn(0,60000)*1000000 }
        if(saved.attempts >= 5 || round <= mono() || saved.roundEnd <= now()) { store.updateAdministration(saved,saved.copy(status = AdministrationStatus.NeedsAttention));return }
        if(saved.nextAttempt > now()) return
        val end = submissionEnds.getOrPut(id) { mono()+(command.admission.expires-now()).coerceIn(0,120000)*1000000 }
        val open = command.admission.expires > now() && end > mono();val recover = !open || saved.reconcile || saved.executionStarted == null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true,submissionStarted = saved.submissionStarted || !recover,attempts = saved.attempts+1)
        store.updateAdministration(saved,work) // Uncertainty precedes every physical submission.
        measureOperationStep(work.intent.action.operationKind(), if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            work.attempts, isRetry, candidatesObserved,
            observe = { store.administrationWork(id)?.takeIf { work.intent == it.intent && work.admission == it.admission }?.operationObservation(now()) }) {
            val next = try {
                val budget = minOf(15000,((round-mono())/1000000).coerceAtLeast(1),if(recover) 15000 else ((end-mono())/1000000).coerceAtLeast(1))
                when(val result = withTimeout(budget) { withCommandAttempt(isRetry) {client.execute(command,recover,close = !open)} }) {
                    is AdministrationResult.Receipt -> work.copy(status = result.status,receipt = result.wire,reason = result.reason)
                    is AdministrationResult.Deferred -> work.copy(nextAttempt = Math.addExact(now(),maxOf(5000,result.delay)))
                    AdministrationResult.Unresolved -> work.copy(reconcile = !open,nextAttempt = now()+5000)
                    AdministrationResult.Conflict -> work.copy(status = AdministrationStatus.NeedsAttention,reason = "fingerprintConflict")
                }
            } catch(e: TimeoutCancellationException) { deferred(work,0,false) }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                val next = deferred(work,(e as? AdministrationBackpressure)?.delay ?: 0,e is IllegalArgumentException || e is ClientFailure.Protocol)
                if(e is ClientFailure.SignedOut) { store.updateAdministration(work,next);throw e };next
            }
            store.updateAdministration(work,if(!next.terminal && (next.attempts >= 5 || round <= mono())) next.copy(status = AdministrationStatus.NeedsAttention) else next)
        }
    }
    private fun deferred(work: AdministrationWork,floor: Long,stop: Boolean) = work.copy(status = if(stop) AdministrationStatus.NeedsAttention else AdministrationStatus.Pending,
        nextAttempt = Math.addExact(now(),maxOf(1000L shl minOf(work.attempts,5),floor)),reason = "confirmationRequired")
}
