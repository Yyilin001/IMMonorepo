package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

/** Owns the atomic boundary between common execution metadata and the existing profile payload. */
internal class SqliteOwnProfileClaims(private val db: SQLiteDatabase, private val actor: UserId,
    private val profiles: SqliteOwnProfile, private val journal: SqliteOperationWork) {
    init { if (!db.isReadOnly) {
        check(db.inTransaction())
        var after = 0L
        while (true) {
            val batch = db.rawQuery("SELECT n.rowid,n.work FROM own_profile_operations n LEFT JOIN operation_work w ON w.id=n.id WHERE w.id IS NULL AND n.rowid>? ORDER BY n.rowid LIMIT 64",
                arrayOf(after.toString())).use { rows -> buildList { while (rows.moveToNext()) add(rows.getLong(0) to Json.decodeFromString<OwnProfileWork>(rows.getString(1))) } }
            if (batch.isEmpty()) break
            // Legacy completed history has no trustworthy completion/creation timestamp.
            batch.forEach { (_, work) -> if (!work.terminal) ensure(work, null) }
            after = batch.last().first
        }
    } }
    private fun read(id: String): OwnProfileWork = db.rawQuery("SELECT work FROM own_profile_operations WHERE id=?", arrayOf(id)).use {
        require(it.moveToFirst()); Json.decodeFromString<OwnProfileWork>(it.getString(0)).also { value -> require(value.command.actor == actor && value.command.operation == id) }
    }
    fun ensure(work: OwnProfileWork, createdAt: Long?): OperationWork {
        journal.read(work.command.operation)?.let { return it }
        require(!work.terminal && work.command.actor == actor)
        // The legacy counter mixed submission and reconciliation rounds. Preserve it
        // conservatively in both budgets; never invent an original creation timestamp.
        val next = OperationWork(id = work.command.operation, actor = actor,
            kind = OperationKind.ProfileUpdate,
            identityKey = work.command.identity().toString(), fingerprint = work.command.fingerprint,
            orderingKey = "profile/${actor.value}", localSequence = 1,
            execution = if (work.submissionStarted) OperationExecutionState.AwaitingConfirmation else OperationExecutionState.Prepared,
            scheduling = if (work.status == OwnProfileStatus.NeedsAttention) OperationSchedulingState.NeedsAttention else if (work.nextAttempt > 0) OperationSchedulingState.BackingOff else OperationSchedulingState.Ready,
            submissionStarted = work.submissionStarted, attemptCount = work.attempts,
            submissionRoundAttempts = work.attempts, reconciliationRoundAttempts = if (work.submissionStarted) work.attempts else 0,
            submissionRoundDeadline = work.roundStarted?.let { Math.addExact(it, 60_000) },
            reconciliationRoundDeadline = work.roundStarted?.takeIf { work.submissionStarted }?.let { Math.addExact(it, 60_000) },
            nextAction = if (work.reconcile || work.submissionStarted) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            nextActionAt = work.nextAttempt, admissionDeadline = work.command.deadline, originalCreatedAt = createdAt)
        return journal.insert(next)
    }
    private fun mirror(work: OwnProfileWork, common: OperationWork): OwnProfileWork {
        val submit = common.nextAction == OperationWorkAction.Submit
        val deadline = if (submit) common.submissionRoundDeadline else common.reconciliationRoundDeadline
        return work.copy(status = when (common.execution) {
            OperationExecutionState.ExpiredUnsubmitted -> OwnProfileStatus.Expired
            else -> if (common.scheduling == OperationSchedulingState.NeedsAttention) OwnProfileStatus.NeedsAttention else OwnProfileStatus.Pending
        }, submissionStarted = common.submissionStarted, reconcile = common.submissionStarted &&
            (common.scheduling == OperationSchedulingState.Claimed || common.nextAction == OperationWorkAction.Reconcile),
            attempts = if (submit) common.submissionRoundAttempts else common.reconciliationRoundAttempts,
            roundStarted = deadline?.minus(60_000), nextAttempt = common.nextActionAt,
            reason = if (common.execution == OperationExecutionState.ExpiredUnsubmitted) "expiredUnsubmitted" else common.lastErrorCode ?: work.reason)
    }
    fun recover(owner: String, now: Long) = journal.recoverForDrainedOwner(owner, now, kotlinx.collections.immutable.persistentSetOf(OperationKind.ProfileUpdate)) { common ->
        val old = read(common.id); if (!old.terminal) profiles.update(old, mirror(old, common))
    }
    fun claim(id: String, owner: String, now: Long): OwnProfileOperationClaim? {
        val old = read(id); if (old.terminal) return null
        val common = ensure(old, null)
        val action = if (old.submissionStarted && now >= old.command.deadline) OperationWorkAction.Reconcile else common.nextAction
        return when (val result = journal.claim(id, owner, action, now)) {
            is OperationWorkClaimResult.Claimed -> {
                val value = mirror(old, result.claim.work); profiles.update(old, value); OwnProfileOperationClaim(result.claim, value)
            }
            OperationWorkClaimResult.ExpiredUnsubmitted, OperationWorkClaimResult.NeedsAttention -> {
                profiles.update(old, mirror(old, requireNotNull(journal.read(id)))); null
            }
            OperationWorkClaimResult.Unavailable -> null
        }
    }
    fun defer(claim: OwnProfileOperationClaim, until: Long, code: String, attention: Boolean, nextAction: OperationWorkAction) {
        val common = journal.defer(claim.claim, until, code,
            if (attention) OperationSchedulingState.NeedsAttention else OperationSchedulingState.BackingOff, nextAction)
        if (common.terminal) return
        val old = read(common.id); profiles.update(old, mirror(old, common))
    }
    fun complete(claim: OwnProfileOperationClaim, result: OwnProfileResult.Receipt, now: Long) {
        val old = read(claim.work.command.operation); require(old.command == claim.work.command)
        val verified = OwnProfileClient.decodeResult(old.command, Json.parseToJsonElement(result.wire).jsonObject)
        require(verified == result)
        val receipt = Json.parseToJsonElement(verified.wire).jsonObject.getValue("receipt").toString()
        if (old.terminal) {
            require(old.status == verified.status && Json.parseToJsonElement(requireNotNull(old.receipt)).jsonObject.getValue("receipt").toString() == receipt)
            verified.snapshot?.let { profiles.save(it) }
        }
        else profiles.update(old, old.copy(status = verified.status, receipt = verified.wire, reason = verified.reason, draftRetained = verified.status != OwnProfileStatus.Committed))
        journal.complete(old.command.operation, old.command.fingerprint, execution(verified.status), receipt, now)
    }
    fun retry(id: String, now: Long) {
        val old = read(id); require(old.status == OwnProfileStatus.NeedsAttention)
        val next = journal.retry(id, now, resetRounds = true); profiles.update(old, mirror(old, next))
    }
    /** Legacy direct callers retain CAS semantics; they cannot replace a currently owned step. */
    fun update(expected: OwnProfileWork, updated: OwnProfileWork, now: Long) {
        val common = ensure(expected, null)
        if (common.scheduling == OperationSchedulingState.Claimed) throw StaleOperationClaim()
        profiles.update(expected, updated)
        val actual = read(updated.command.operation)
        if (actual.status == OwnProfileStatus.Expired) {
            journal.synchronize(common.copy(execution = OperationExecutionState.ExpiredUnsubmitted,
                scheduling = OperationSchedulingState.Finished, completedAt = now)); return
        }
        val mapped = common.copy(execution = if (actual.submissionStarted) OperationExecutionState.AwaitingConfirmation else OperationExecutionState.Prepared,
            scheduling = if (actual.status == OwnProfileStatus.NeedsAttention) OperationSchedulingState.NeedsAttention else if (actual.nextAttempt > 0) OperationSchedulingState.BackingOff else OperationSchedulingState.Ready,
            submissionStarted = actual.submissionStarted,
            attemptCount = Math.addExact(common.attemptCount, (actual.attempts - expected.attempts).coerceAtLeast(0)),
            submissionRoundAttempts = actual.attempts, reconciliationRoundAttempts = if (actual.submissionStarted) actual.attempts else 0,
            submissionRoundDeadline = actual.roundStarted?.let { Math.addExact(it, 60_000) },
            reconciliationRoundDeadline = actual.roundStarted?.takeIf { actual.submissionStarted }?.let { Math.addExact(it, 60_000) },
            nextAction = if (actual.reconcile) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            nextActionAt = actual.nextAttempt)
        journal.synchronize(mapped)
        if (actual.terminal) journal.complete(actual.command.operation, actual.command.fingerprint, execution(actual.status), Json.parseToJsonElement(requireNotNull(actual.receipt)).jsonObject.getValue("receipt").toString(), now)
    }
    private fun execution(status: OwnProfileStatus) = when (status) {
        OwnProfileStatus.Committed -> OperationExecutionState.Committed
        OwnProfileStatus.Rejected -> OperationExecutionState.Rejected
        OwnProfileStatus.Conflicted -> OperationExecutionState.Conflicted
        OwnProfileStatus.Closed -> OperationExecutionState.Closed
        else -> error("Not an authoritative terminal profile outcome")
    }
}
