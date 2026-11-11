package com.xmtx.im.client

import kotlinx.coroutines.*

/** One bounded dispatcher turn, using persisted leases and independent submit/reconcile rounds. */
internal class DurableOwnProfileOperationRunner(private val actor: UserId, private val client: OwnProfileTransport,
    private val store: OwnProfileOperationClaimStore, private val owner: String, private val now: () -> Long) {
    suspend fun flush() {
        val candidates = store.dueOperationWork(now(), 32, kotlinx.collections.immutable.persistentSetOf(OperationKind.ProfileUpdate))
        val observed = System.nanoTime(); var claimed = 0
        for (candidate in candidates) {
            require(candidate.actor == actor)
            if (candidate.kind !in setOf(OperationKind.ProfileUpdate)) continue
            if (claimed >= 4) break
            val attempt = store.claimOwnProfile(candidate.id, owner, now()) ?: continue
            claimed++
            val common = attempt.claim.work; val work = attempt.work
            val submit = attempt.claim.action == OperationWorkAction.Submit
            val attempts = if (submit) common.submissionRoundAttempts else common.reconciliationRoundAttempts
            val roundDeadline = requireNotNull(if (submit) common.submissionRoundDeadline else common.reconciliationRoundDeadline)
            val close = now() >= work.command.deadline
            measureOperationStep(common.kind, attempt.claim.action, attempts, common.attemptCount > 1 || !submit, observed,
                observe = { store.operationWork(common.id)?.let { OperationStepObservation(it.execution, it.scheduling) } }) {
                var cancelled = false
                try {
                    val remaining = (roundDeadline - now()).coerceAtLeast(0)
                    if (remaining == 0L) {
                        store.deferOwnProfile(attempt, now(), "ROUND_EXHAUSTED", true, OperationWorkAction.Reconcile)
                        return@measureOperationStep
                    }
                    val result = withTimeout(minOf(15_000L, remaining)) {
                        withCommandAttempt(common.attemptCount > 1 || !submit) {
                            if (submit) client.submit(work.command) else client.recover(work.command, close)
                        }
                    }
                    when (result) {
                        is OwnProfileResult.Receipt -> store.completeOwnProfile(attempt, result, now())
                        OwnProfileResult.Conflict -> store.deferOwnProfile(attempt, now(), "fingerprintConflict", true, OperationWorkAction.Reconcile)
                        OwnProfileResult.Unresolved -> {
                            val next = sendTimeAfter(now(), 5_000)
                            store.deferOwnProfile(attempt, next, "unresolved", attempts >= 5 || next >= roundDeadline,
                                if (close) OperationWorkAction.Reconcile else OperationWorkAction.Submit)
                        }
                    }
                } catch (error: CancellationException) {
                    if (error is TimeoutCancellationException && currentCoroutineContext().isActive) {
                        deferFailure(attempt, attempts, roundDeadline, error)
                    } else {
                        cancelled = true
                        throw error
                    }
                } catch (_: StaleOperationClaim) {
                    // An old failure cannot mutate a newer claim or its authoritative outcome.
                } catch (error: Exception) {
                    currentCoroutineContext().ensureActive()
                    deferFailure(attempt, attempts, roundDeadline, error)
                    if (error is ClientFailure.SignedOut) throw error
                } finally {
                    if (cancelled || !currentCoroutineContext().isActive) {
                        // Also covers outer timeouts and cancellation while writing a failure.
                        // The physical child has unwound before relinquishing its durable claim.
                        withContext(NonCancellable) { runCatching { store.deferOwnProfile(attempt, now(), "STEP_CANCELLED", false, OperationWorkAction.Reconcile) } }
                    }
                }
            }
        }
    }
    private suspend fun deferFailure(attempt: OwnProfileOperationClaim, attempts: Int, deadline: Long, error: Exception) {
        val failure = error as? ClientFailure.Http
        val hint = failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it, now()) }.getOrDefault(86_400_000) } ?: 0
        val delay = maxOf(hint, minOf(30_000L, 1_000L shl attempts.coerceIn(0, 5)))
        val next = sendTimeAfter(now(), delay)
        val permanent = error is ClientFailure.Protocol || error is IllegalArgumentException || failure?.status in setOf(400, 403, 404, 409, 413, 415, 422)
        try { store.deferOwnProfile(attempt, next, "confirmationRequired", permanent || attempts >= 5 || next >= deadline, OperationWorkAction.Reconcile) }
        catch (_: StaleOperationClaim) { }
    }
}
