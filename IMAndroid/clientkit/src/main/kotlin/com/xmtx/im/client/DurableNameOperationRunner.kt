package com.xmtx.im.client

import kotlinx.coroutines.*

/** One bounded dispatcher turn, using persisted leases and independent submit/reconcile rounds. */
internal class DurableNameOperationRunner(private val actor: UserId, private val client: NameTransport,
    private val store: NameOperationClaimStore, private val owner: String, private val now: () -> Long) {
    suspend fun flush() {
        val candidates = store.dueOperationWork(now(), 32, kotlinx.collections.immutable.persistentSetOf(OperationKind.ContactAlias, OperationKind.GroupNickname))
        val observed = System.nanoTime(); var claimed = 0
        for (candidate in candidates) {
            require(candidate.actor == actor)
            if (candidate.kind !in setOf(OperationKind.ContactAlias, OperationKind.GroupNickname)) continue
            if (claimed >= 4) break
            val attempt = store.claimName(candidate.id, owner, now()) ?: continue
            claimed++
            val common = attempt.claim.work; val work = attempt.work
            val submit = attempt.claim.action == OperationWorkAction.Submit
            val attempts = if (submit) common.submissionRoundAttempts else common.reconciliationRoundAttempts
            val roundDeadline = requireNotNull(if (submit) common.submissionRoundDeadline else common.reconciliationRoundDeadline)
            val close = work.closeRequested || now() >= work.command.deadline
            measureOperationStep(common.kind, attempt.claim.action, attempts, common.attemptCount > 1 || !submit, observed,
                observe = { store.operationWork(common.id)?.let { OperationStepObservation(it.execution, it.scheduling) } }) {
                var cancelled = false
                try {
                    val remaining = (roundDeadline - now()).coerceAtLeast(0)
                    if (remaining == 0L) {
                        store.deferName(attempt, now(), "ROUND_EXHAUSTED", true, OperationWorkAction.Reconcile)
                        return@measureOperationStep
                    }
                    val result = withTimeout(minOf(15_000L, remaining)) {
                        withCommandAttempt(common.attemptCount > 1 || !submit) {
                            if (submit) client.submit(work.command) else client.recover(work.command, close)
                        }
                    }
                    when (result) {
                        is NameResult.Receipt -> store.completeName(attempt, result, now())
                        NameResult.Conflict -> store.deferName(attempt, now(), "fingerprintConflict", true, OperationWorkAction.Reconcile)
                        NameResult.Unresolved -> {
                            val next = sendTimeAfter(now(), 5_000)
                            store.deferName(attempt, next, "unresolved", attempts >= 5 || next >= roundDeadline,
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
                        withContext(NonCancellable) { runCatching { store.deferName(attempt, now(), "STEP_CANCELLED", false, OperationWorkAction.Reconcile) } }
                    }
                }
            }
        }
    }
    private suspend fun deferFailure(attempt: NameOperationClaim, attempts: Int, deadline: Long, error: Exception) {
        val failure = error as? ClientFailure.Http
        val hint = failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it, now()) }.getOrDefault(86_400_000) } ?: 0
        val delay = maxOf(hint, minOf(30_000L, 1_000L shl attempts.coerceIn(0, 5)))
        val next = sendTimeAfter(now(), delay)
        val permanent = error is ClientFailure.Protocol || error is IllegalArgumentException || failure?.status in setOf(400, 403, 404, 409, 413, 415, 422)
        try { store.deferName(attempt, next, "confirmationRequired", permanent || attempts >= 5 || next >= deadline, OperationWorkAction.Reconcile) }
        catch (_: StaleOperationClaim) { }
    }
}
