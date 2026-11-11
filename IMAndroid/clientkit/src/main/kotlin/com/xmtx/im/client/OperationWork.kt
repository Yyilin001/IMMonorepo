package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.serialization.Serializable

/** Immutable journal metadata. A snapshot never authorizes network I/O. Times are epoch milliseconds. */
@Serializable data class OperationWork(
    val id: String, val actor: UserId, val kind: OperationKind, val identityKey: String, val fingerprint: String,
    val orderingKey: String, val localSequence: Long,
    val execution: OperationExecutionState = OperationExecutionState.Prepared,
    val scheduling: OperationSchedulingState = OperationSchedulingState.Ready,
    val submissionStarted: Boolean = false, val attemptCount: Int = 0,
    val submissionRoundAttempts: Int = 0, val reconciliationRoundAttempts: Int = 0,
    val submissionRoundDeadline: Long? = null, val reconciliationRoundDeadline: Long? = null,
    val nextAction: OperationWorkAction = OperationWorkAction.Submit, val nextActionAt: Long,
    val admissionDeadline: Long?, val originalCreatedAt: Long?, val revision: Long = 1,
    val lastErrorCode: String? = null, val completedAt: Long? = null,
) {
    init {
        require(uuidId(id) == id && localSequence > 0 && revision > 0)
        require(identityKey.isNotEmpty() && identityKey.toByteArray().size <= 2_048)
        require(java.util.Base64.getDecoder().decode(fingerprint).size == 32 &&
            java.util.Base64.getEncoder().encodeToString(java.util.Base64.getDecoder().decode(fingerprint)) == fingerprint)
        require(orderingKey.isNotEmpty() && orderingKey.toByteArray().size <= 512 && orderingKey.none { it.code < 32 })
        require(attemptCount >= 0 && submissionRoundAttempts >= 0 && reconciliationRoundAttempts >= 0)
        require(nextActionAt >= 0 && listOfNotNull(submissionRoundDeadline, reconciliationRoundDeadline, admissionDeadline, originalCreatedAt, completedAt).all { it >= 0 })
        require(lastErrorCode == null || lastErrorCode.isNotEmpty() && lastErrorCode.toByteArray().size <= 128)
        require(terminal == (scheduling == OperationSchedulingState.Finished) && terminal == (completedAt != null))
        require(execution !in setOf(OperationExecutionState.Submitting, OperationExecutionState.Processing, OperationExecutionState.AwaitingConfirmation) || submissionStarted)
        require(execution !in setOf(OperationExecutionState.Prepared, OperationExecutionState.CancelledLocally, OperationExecutionState.ExpiredUnsubmitted) || !submissionStarted)
    }
    val terminal get() = execution in setOf(OperationExecutionState.Committed, OperationExecutionState.Rejected,
        OperationExecutionState.Conflicted, OperationExecutionState.Closed, OperationExecutionState.CancelledLocally, OperationExecutionState.ExpiredUnsubmitted)
}

/** Token, owner and revision must all match for non-authoritative callbacks. */
data class OperationWorkClaim(val work: OperationWork, val action: OperationWorkAction, val owner: String, val token: String) {
    init { require(uuidId(owner) == owner && uuidId(token) == token && work.scheduling == OperationSchedulingState.Claimed) }
}
sealed interface OperationWorkClaimResult {
    data class Claimed(val claim: OperationWorkClaim): OperationWorkClaimResult
    data object Unavailable: OperationWorkClaimResult
    data object ExpiredUnsubmitted: OperationWorkClaimResult
    data object NeedsAttention: OperationWorkClaimResult
}
class StaleOperationClaim : IllegalStateException("操作领取已失效")

interface OperationWorkReading {
    /** Explicit adapter coverage; this is not a claim that every domain has migrated. */
    val operationWorkKinds: PersistentSet<OperationKind>
    suspend fun operationWork(id: String): OperationWork?
    suspend fun dueOperationWork(now: Long, limit: Int = 32, kinds: PersistentSet<OperationKind>? = null): PersistentList<OperationWork>
}

/** Shared write-ahead policy. Ordering, dependencies and ownership are checked in the store transaction. */
object OperationWorkClaimPolicy {
    sealed interface Decision {
        data object Unavailable: Decision
        data class Claimed(val work: OperationWork, val action: OperationWorkAction): Decision
        data class ExpiredUnsubmitted(val work: OperationWork): Decision
        data class NeedsAttention(val work: OperationWork): Decision
    }
    fun claim(work: OperationWork, action: OperationWorkAction, now: Long,
        maximumAutomaticAttempts: Int = 5, roundMilliseconds: Long = 60_000): Decision {
        // Other adapters (especially sensitive admissions requiring query/close on expiry)
        // must add their domain rule before entering this policy.
        require(work.kind in setOf(OperationKind.ContactAlias, OperationKind.GroupNickname, OperationKind.ProfileUpdate))
        require(now >= 0 && maximumAutomaticAttempts > 0 && roundMilliseconds > 0 && now <= Long.MAX_VALUE - roundMilliseconds)
        if (work.scheduling !in setOf(OperationSchedulingState.Ready, OperationSchedulingState.BackingOff) || work.nextActionAt > now) return Decision.Unavailable
        val expired = work.admissionDeadline?.let { it <= now } == true
        if (!work.submissionStarted && expired) return Decision.ExpiredUnsubmitted(work.copy(
            execution = OperationExecutionState.ExpiredUnsubmitted, scheduling = OperationSchedulingState.Finished,
            completedAt = now, revision = Math.addExact(work.revision, 1)))
        if (action == OperationWorkAction.Submit && work.submissionStarted && expired) return Decision.Unavailable
        val attempts = if (action == OperationWorkAction.Submit) work.submissionRoundAttempts else work.reconciliationRoundAttempts
        val deadline = if (action == OperationWorkAction.Submit) work.submissionRoundDeadline else work.reconciliationRoundDeadline
        if (work.attemptCount == Int.MAX_VALUE || attempts >= maximumAutomaticAttempts || deadline?.let { it <= now } == true)
            return Decision.NeedsAttention(work.copy(scheduling = OperationSchedulingState.NeedsAttention, revision = Math.addExact(work.revision, 1)))
        if (action == OperationWorkAction.Submit && work.execution !in setOf(OperationExecutionState.Prepared, OperationExecutionState.AwaitingConfirmation) ||
            action == OperationWorkAction.Reconcile && !work.submissionStarted) return Decision.Unavailable
        val submit = action == OperationWorkAction.Submit
        return Decision.Claimed(work.copy(execution = if (submit) OperationExecutionState.Submitting else work.execution,
            scheduling = OperationSchedulingState.Claimed, submissionStarted = true, attemptCount = work.attemptCount + 1,
            submissionRoundAttempts = work.submissionRoundAttempts + if (submit) 1 else 0,
            reconciliationRoundAttempts = work.reconciliationRoundAttempts + if (submit) 0 else 1,
            submissionRoundDeadline = if (submit) deadline ?: now + roundMilliseconds else work.submissionRoundDeadline,
            reconciliationRoundDeadline = if (submit) work.reconciliationRoundDeadline else deadline ?: now + roundMilliseconds,
            nextAction = action, revision = Math.addExact(work.revision, 1)), action)
    }
}
