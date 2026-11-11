package com.xmtx.im.client

import kotlin.test.*
import org.junit.Test
import java.util.UUID

class OperationWorkClaimPolicyTests {
    private fun fresh(): OperationWork {
        val actor = UserId(UUID.randomUUID().toString())
        val command = NameCommand(actor, NameTarget.Contact(UserId(UUID.randomUUID().toString())), UUID.randomUUID().toString().uppercase(), "备注", null, 100_000)
        return OperationWork(command.operation, actor, OperationKind.ContactAlias, command.identity().toString(), command.fingerprint, command.target.key, 1,
            nextActionAt = 1_000, admissionDeadline = command.deadline, originalCreatedAt = 1_000)
    }
    @Test fun `submission and reconciliation consume separate immutable rounds`() {
        val original = fresh()
        val submit = assertIs<OperationWorkClaimPolicy.Decision.Claimed>(OperationWorkClaimPolicy.claim(original, OperationWorkAction.Submit, 1_000)).work
        val ready = submit.copy(execution = OperationExecutionState.AwaitingConfirmation, scheduling = OperationSchedulingState.Ready)
        val recovery = assertIs<OperationWorkClaimPolicy.Decision.Claimed>(OperationWorkClaimPolicy.claim(ready, OperationWorkAction.Reconcile, 2_000)).work
        assertEquals(0, original.attemptCount); assertFalse(original.submissionStarted)
        assertEquals(2, recovery.attemptCount); assertEquals(1, recovery.submissionRoundAttempts); assertEquals(1, recovery.reconciliationRoundAttempts)
        assertEquals(61_000L, recovery.submissionRoundDeadline); assertEquals(62_000L, recovery.reconciliationRoundDeadline)
        assertEquals(original.fingerprint, recovery.fingerprint); assertEquals(original.admissionDeadline, recovery.admissionDeadline)
    }
    @Test fun `first expiry is local but uncertain work may only reconcile`() {
        val first = fresh()
        val expired = assertIs<OperationWorkClaimPolicy.Decision.ExpiredUnsubmitted>(OperationWorkClaimPolicy.claim(first, OperationWorkAction.Submit, 100_000)).work
        assertFalse(expired.submissionStarted); assertEquals(OperationSchedulingState.Finished, expired.scheduling)
        val uncertain = first.copy(submissionStarted = true, execution = OperationExecutionState.AwaitingConfirmation)
        assertEquals(OperationWorkClaimPolicy.Decision.Unavailable, OperationWorkClaimPolicy.claim(uncertain, OperationWorkAction.Submit, 100_000))
        assertIs<OperationWorkClaimPolicy.Decision.Claimed>(OperationWorkClaimPolicy.claim(uncertain, OperationWorkAction.Reconcile, 100_000))
        assertFailsWith<IllegalArgumentException> { OperationWorkClaimPolicy.claim(first.copy(kind = OperationKind.GroupInvite), OperationWorkAction.Submit, 100_000) }
    }
    @Test fun `exhaustion and cooldown cannot be bypassed by another read snapshot`() {
        val first = fresh()
        assertEquals(OperationWorkClaimPolicy.Decision.Unavailable, OperationWorkClaimPolicy.claim(first, OperationWorkAction.Submit, 999))
        val exhausted = first.copy(submissionRoundAttempts = 5, attemptCount = 5, submissionStarted = true, execution = OperationExecutionState.AwaitingConfirmation)
        assertIs<OperationWorkClaimPolicy.Decision.NeedsAttention>(OperationWorkClaimPolicy.claim(exhausted, OperationWorkAction.Submit, 1_000))
        assertIs<OperationWorkClaimPolicy.Decision.Claimed>(OperationWorkClaimPolicy.claim(exhausted, OperationWorkAction.Reconcile, 1_000))
        assertIs<OperationWorkClaimPolicy.Decision.NeedsAttention>(OperationWorkClaimPolicy.claim(first.copy(attemptCount = Int.MAX_VALUE), OperationWorkAction.Submit, 1_000))
        val claimed = assertIs<OperationWorkClaimPolicy.Decision.Claimed>(OperationWorkClaimPolicy.claim(first, OperationWorkAction.Submit, 1_000)).work
        assertEquals(OperationWorkClaimPolicy.Decision.Unavailable, OperationWorkClaimPolicy.claim(claimed, OperationWorkAction.Reconcile, 80_000))
    }
}
