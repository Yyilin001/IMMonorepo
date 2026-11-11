package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

data class InvitationConfirmation(val intent: InvitationIntent, val deadlineNanos: Long, val activation: String)
class InvitationSecretUnavailable : Exception("Invitation secret unavailable")
class InvitationService(private val actor: UserId, private val client: InvitationClient, private val store: InvitationStore,
    private val secrets: InvitationSecretStore, private val now: () -> Long = System::currentTimeMillis,
    private val mono: () -> Long = System::nanoTime) {
    private val activation = UUID.randomUUID().toString()
    private val confirmations = mutableMapOf<String,Long>()
    private val preparationEnds = mutableMapOf<String,Long>()
    private val submissionEnds = mutableMapOf<String,Long>()
    private val roundEnds = mutableMapOf<String,Long>()
    private val mutex = Mutex()
    fun confirmation(room: RoomId, action: InvitationAction): InvitationConfirmation {
        val normalized = if(action is InvitationAction.Submit) action.copy(note = invitationNote(action.note)) else action
        return InvitationConfirmation(InvitationIntent(actor, room, UUID.randomUUID().toString().uppercase(), normalized,
            Math.addExact(now(), ClientSubmissionWindow.CONFIRMATION_MILLISECONDS)), mono() + ClientSubmissionWindow.CONFIRMATION_MILLISECONDS * 1000000, activation)
    }
    private fun validate(value: InvitationConfirmation) {
        require(value.activation == activation && value.intent.actor == actor && value.deadlineNanos > mono() && value.intent.deadline > now()) { "请刷新后重新确认邀请操作" }
    }
    suspend fun enqueue(value: InvitationConfirmation, secret: InvitationSecret? = null) = mutex.withLock {
        validate(value); value.intent.validateSecret(secret)
        val reference = secret?.let { UUID.randomUUID().toString().uppercase().also { id -> secrets.save(id, actor, secret) } }
        val work = try { store.prepareInvitation(value.intent, activation, reference) }
        catch(error: Exception) { if(reference != null) withContext(NonCancellable) { runCatching { secrets.remove(reference, actor) } }; throw error }
        if(reference != null && work.secretReference != reference) secrets.remove(reference, actor)
        confirmations[value.intent.key] = value.deadlineNanos; work
    }
    suspend fun reconfirm(id: String, value: InvitationConfirmation) = mutex.withLock {
        validate(value); val old = owned(id)
        require(old.status == InvitationStatus.DraftPaused && old.intent.room == value.intent.room && old.intent.action.sameProposal(value.intent.action))
        store.replaceInvitationDraft(old, value.intent, activation).also { confirmations[value.intent.key] = value.deadlineNanos; confirmations.remove(id) }
    }
    suspend fun discard(id: String) = mutex.withLock {
        val work = owned(id); require(work.draft && !work.terminal && work.admission == null && !work.submissionStarted && !work.recoveryOnly)
        store.updateInvitation(work, work.copy(status = InvitationStatus.DraftCancelled, releaseSecret = work.secretReference != null)); releaseSecrets()
    }
    suspend fun retry(id: String) = mutex.withLock {
        val work = owned(id); require(!work.draft && !work.terminal)
        store.updateInvitation(work, work.copy(status = InvitationStatus.Pending, executionStarted = commandExecutionStarted(work.executionStarted), attempts = 0, roundEnd = now() + 60000))
        roundEnds[id] = mono() + 60000000000
    }
    suspend fun closeOriginal(id: String) = mutex.withLock {
        val work = owned(id); require(work.draft && !work.terminal)
        store.updateInvitation(work, work.copy(executionStarted = false,status = InvitationStatus.Pending, recoveryOnly = true, reconcile = true, roundEnd = now() + 60000))
        roundEnds[id] = mono() + 60000000000
    }
    private suspend fun owned(id: String) = store.invitationWorks().first { it.intent.key == id }.also { require(it.intent.actor == actor) }
    private suspend fun secret(work: InvitationWork): InvitationSecret? {
        if(work.intent.action !is InvitationAction.Submit) return null
        val reference = work.secretReference ?: throw InvitationSecretUnavailable()
        val value = try { secrets.load(reference, actor) } catch(e: CancellationException) { throw e } catch(_: Exception) { throw InvitationSecretUnavailable() }
        require(value.digest == work.intent.action.tokenDigest); return value
    }
    suspend fun flush() = mutex.withLock {
        releaseSecrets()
        val candidates = store.invitationWorks(); val candidatesObserved = System.nanoTime()
        for(work in candidates) {
            require(work.intent.actor == actor)
            if(work.terminal) continue
            when(work.status) {
                InvitationStatus.DraftReady -> if(work.nextAttempt <= now() || work.activation != activation) prepare(work)
                InvitationStatus.Pending -> execute(work, candidatesObserved)
                else -> Unit
            }
        }
        releaseSecrets()
    }
    private suspend fun prepare(saved: InvitationWork) {
        val id = saved.intent.key; val confirmation = confirmations[id]
        val end = preparationEnds.getOrPut(id) { minOf(confirmation ?: mono(), mono() + (if(saved.preparationEnd > 0) saved.preparationEnd - now() else 60000).coerceIn(0,60000) * 1000000) }
        if(saved.activation != activation || confirmation == null || end <= mono() || saved.intent.deadline <= now() || saved.preparationAttempts >= 5) {
            store.updateInvitation(saved, saved.copy(status = InvitationStatus.DraftPaused, reason = "confirmationRequired")); return
        }
        val work = saved.copy(preparationAttempts = saved.preparationAttempts + 1, preparationEnd = if(saved.preparationEnd > 0) saved.preparationEnd else minOf(now() + 60000, saved.intent.deadline))
        store.updateInvitation(saved, work)
        try {
            val result = withTimeout(minOf(15000, ((end - mono()) / 1000000).coerceAtLeast(1))) { withPreparationAttempt(work.preparationAttempts) {client.admit(work.intent, secret(work))} }
            when(result) {
                is InvitationAdmissionResult.Admitted -> {
                    if(end <= mono() || now() >= work.intent.deadline) { store.updateInvitation(work, work.copy(status = InvitationStatus.DraftPaused, reason = "confirmationRequired")); return }
                    store.updateInvitation(work, work.copy(executionStarted = false,admission = result.admission, status = InvitationStatus.Pending, nextAttempt = 0, roundEnd = now() + 60000, reason = null))
                    submissionEnds[id] = minOf(confirmation, mono() + (result.admission.expiresAt - now()).coerceIn(0,120000) * 1000000)
                    roundEnds[id] = mono() + 60000000000
                }
                is InvitationAdmissionResult.Terminal -> store.updateInvitation(work, work.copy(executionStarted = false,status = InvitationStatus.Pending, recoveryOnly = true, reconcile = true, roundEnd = now() + 60000))
                is InvitationAdmissionResult.Unavailable -> store.updateInvitation(work, work.copy(status = InvitationStatus.DraftPaused, reason = result.reason))
                InvitationAdmissionResult.Conflict -> store.updateInvitation(work, work.copy(status = InvitationStatus.DraftPaused, reason = "fingerprintConflict"))
            }
        } catch(e: TimeoutCancellationException) { deferPreparation(work, end, 0, false) }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            deferPreparation(work, end, (e as? InvitationBackpressure)?.delay ?: 0, e is InvitationSecretUnavailable || e is IllegalArgumentException || e is ClientFailure.Protocol)
            if(e is ClientFailure.SignedOut) throw e
        }
    }
    private suspend fun deferPreparation(work: InvitationWork, end: Long, floor: Long, stop: Boolean) {
        val delay = maxOf(minOf(8000, 1000L shl work.preparationAttempts), floor); val next = Math.addExact(now(), delay)
        val pause = stop || work.preparationAttempts >= 5 || end - mono() <= delay * 1000000 || next >= work.intent.deadline
        store.updateInvitation(work, work.copy(status = if(pause) InvitationStatus.DraftPaused else InvitationStatus.DraftReady, nextAttempt = next, reason = "confirmationRequired"))
    }
    private suspend fun execute(saved: InvitationWork, candidatesObserved: Long) {
        val id = saved.intent.key
        val round = roundEnds.getOrPut(id) { mono() + (saved.roundEnd - now()).coerceIn(0,60000) * 1000000 }
        if(saved.attempts >= 5 || round <= mono() || saved.roundEnd <= now()) {
            store.updateInvitation(saved, saved.copy(status = InvitationStatus.NeedsAttention)); return
        }
        if(saved.nextAttempt > now()) return
        val submitEnd = submissionEnds.getOrPut(id) { mono() + ((saved.admission?.expiresAt ?: saved.intent.deadline) - now()).coerceIn(0,120000) * 1000000 }
        val open = !saved.recoveryOnly && saved.admission != null && saved.admission.expiresAt > now() && submitEnd > mono()
        val recover = !open || saved.reconcile || saved.executionStarted == null
        val isRetry = commandExecutionStarted(saved.executionStarted)
        val work = saved.copy(executionStarted = true,reconcile = true, submissionStarted = saved.submissionStarted || !recover, attempts = saved.attempts + 1)
        store.updateInvitation(saved, work)
        measureOperationStep(work.intent.action.operationKind(), if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            work.attempts, isRetry, candidatesObserved,
            observe = { store.invitationWork(id)?.takeIf { work.intent == it.intent && work.admission == it.admission }?.operationObservation(now()) }) {
            val next = try {
                val budget = minOf(15000, ((round - mono()) / 1000000).coerceAtLeast(1), if(!recover) ((submitEnd - mono()) / 1000000).coerceAtLeast(1) else 15000)
                when(val result = withTimeout(budget) { withCommandAttempt(isRetry) {client.execute(work.intent, work.command(), if(recover) null else secret(work), recover, close = !open)} }) {
                    is InvitationResult.Receipt -> work.copy(status = result.status, receipt = result.wire, reason = result.reason, releaseSecret = work.secretReference != null)
                    InvitationResult.Conflict -> work.copy(status = InvitationStatus.NeedsAttention, reason = "fingerprintConflict")
                    InvitationResult.Unresolved -> work.copy(reconcile = !open, nextAttempt = now() + 5000)
                    is InvitationResult.Deferred -> work.copy(nextAttempt = Math.addExact(now(), maxOf(5000, result.delay)))
                }
            } catch(e: TimeoutCancellationException) { deferred(work, 0, false) }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                val next = deferred(work, (e as? InvitationBackpressure)?.delay ?: 0, e is InvitationSecretUnavailable || e is IllegalArgumentException || e is ClientFailure.Protocol)
                if(e is ClientFailure.SignedOut) { store.updateInvitation(work, next); throw e }; next
            }
            store.updateInvitation(work, if(!next.terminal && (next.attempts >= 5 || round <= mono())) next.copy(status = InvitationStatus.NeedsAttention) else next)
        }
    }
    private fun deferred(work: InvitationWork, floor: Long, stop: Boolean) = work.copy(
        status = if(stop) InvitationStatus.NeedsAttention else InvitationStatus.Pending,
        nextAttempt = Math.addExact(now(), maxOf(1000L shl minOf(work.attempts,5), floor)), reason = "confirmationRequired")
    private suspend fun releaseSecrets() {
        for(work in store.invitationWorks().filter { it.releaseSecret && it.secretReference != null }) {
            require(work.intent.actor == actor)
            try { secrets.remove(requireNotNull(work.secretReference), actor) }
            catch(e: CancellationException) { throw e } catch(_: Exception) { continue }
            store.updateInvitation(work, work.copy(secretReference = null, releaseSecret = false))
        }
    }
}
