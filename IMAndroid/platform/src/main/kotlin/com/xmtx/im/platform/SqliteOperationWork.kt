package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.UUID

/** Common execution journal. Domain payloads and verified receipts remain in their original tables. */
internal class SqliteOperationWork(private val db: SQLiteDatabase, private val actor: UserId) {
    init { if (!db.isReadOnly) {
        check(db.inTransaction())
        db.execSQL("""CREATE TABLE IF NOT EXISTS operation_work(
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,identity_key TEXT UNIQUE NOT NULL,
            ordering_key TEXT NOT NULL,kind TEXT NOT NULL,execution TEXT NOT NULL,scheduling TEXT NOT NULL,
            next_at INTEGER NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),payload TEXT NOT NULL,
            claim_id TEXT,claim_owner TEXT,claim_until INTEGER,receipt_digest TEXT,
            CHECK((claim_id IS NULL)=(claim_owner IS NULL)),CHECK((claim_id IS NULL)=(claim_until IS NULL)),
            CHECK((claim_id IS NOT NULL)=(scheduling='Claimed')))
        """.trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS operation_work_due ON operation_work(next_at,sequence) WHERE scheduling IN ('Ready','BackingOff')")
        db.execSQL("CREATE INDEX IF NOT EXISTS operation_work_order ON operation_work(ordering_key,sequence) WHERE scheduling<>'Finished'")
        db.execSQL("""CREATE TABLE IF NOT EXISTS operation_work_dependencies(
            child TEXT NOT NULL REFERENCES operation_work(id) ON DELETE RESTRICT,
            parent TEXT NOT NULL REFERENCES operation_work(id) ON DELETE RESTRICT,
            PRIMARY KEY(child,parent),CHECK(child<>parent))""".trimIndent())
        db.execSQL("CREATE INDEX IF NOT EXISTS operation_work_dependency_parent ON operation_work_dependencies(parent,child)")
    } }
    private val runnable = """
        NOT EXISTS(SELECT 1 FROM operation_work p WHERE p.ordering_key=w.ordering_key AND p.sequence<w.sequence AND p.scheduling<>'Finished')
        AND NOT EXISTS(SELECT 1 FROM operation_work_dependencies d LEFT JOIN operation_work p ON p.id=d.parent WHERE d.child=w.id AND (p.id IS NULL OR p.execution<>'Committed'))
    """.trimIndent()

    fun read(id: String): OperationWork? = db.rawQuery("SELECT payload FROM operation_work WHERE id=?", arrayOf(id)).use {
        if (it.moveToFirst()) Json.decodeFromString<OperationWork>(it.getString(0)).also { work -> require(work.actor == actor && work.id == id) } else null
    }
    fun due(now: Long, limit: Int, kinds: PersistentSet<OperationKind>? = null): PersistentList<OperationWork> {
        require(now >= 0 && limit in 1..32)
        if (kinds != null && kinds.isEmpty()) return persistentListOf()
        val filter = kinds?.joinToString(",", " AND w.kind IN (", ")") { "?" } ?: ""
        return db.rawQuery("SELECT w.id FROM operation_work w WHERE w.scheduling IN ('Ready','BackingOff') AND w.next_at<=?$filter AND $runnable ORDER BY w.next_at,w.sequence LIMIT ?",
            (listOf(now.toString()) + kinds.orEmpty().map { it.name } + limit.toString()).toTypedArray()).use { rows -> buildList { while (rows.moveToNext()) add(requireNotNull(read(rows.getString(0)))) }.toPersistentList() }
    }
    /** Parents pre-exist and cannot be edited, so a dependency cycle cannot be inserted. */
    fun insert(input: OperationWork, dependencies: PersistentList<String> = persistentListOf()): OperationWork {
        check(db.inTransaction()); require(input.actor == actor && input.scheduling != OperationSchedulingState.Claimed)
        require(dependencies.size <= 32 && dependencies.distinct().size == dependencies.size && input.id !in dependencies)
        read(input.id)?.let { old ->
            require(old.kind == input.kind && old.identityKey == input.identityKey && old.fingerprint == input.fingerprint && old.orderingKey == input.orderingKey && old.admissionDeadline == input.admissionDeadline)
            val parents = db.rawQuery("SELECT parent FROM operation_work_dependencies WHERE child=?", arrayOf(old.id)).use { rows -> buildSet { while (rows.moveToNext()) add(rows.getString(0)) } }
            require(parents == dependencies.toSet()); return old
        }
        dependencies.forEach { requireNotNull(read(it)) { "Operation dependency unavailable" } }
        db.execSQL("INSERT INTO operation_work(id,identity_key,ordering_key,kind,execution,scheduling,next_at,revision,payload) VALUES (?,?,?,?,?,?,?,?,?)",
            arrayOf<Any>(input.id, input.identityKey, input.orderingKey, input.kind.name, input.execution.name, input.scheduling.name, input.nextActionAt, input.revision, Json.encodeToString(input)))
        val sequence = db.rawQuery("SELECT sequence FROM operation_work WHERE id=?", arrayOf(input.id)).use { check(it.moveToFirst()); it.getLong(0) }
        val value = input.copy(localSequence = sequence)
        put(value)
        dependencies.forEach { db.execSQL("INSERT INTO operation_work_dependencies VALUES (?,?)", arrayOf(value.id, it)) }
        return value
    }
    private fun put(work: OperationWork, token: String? = null, owner: String? = null, until: Long? = null) {
        check(db.inTransaction()); require(work.actor == actor)
        require((token != null) == (work.scheduling == OperationSchedulingState.Claimed))
        db.execSQL("UPDATE operation_work SET execution=?,scheduling=?,next_at=?,revision=?,payload=?,claim_id=?,claim_owner=?,claim_until=? WHERE id=?",
            arrayOf<Any?>(work.execution.name, work.scheduling.name, work.nextActionAt, work.revision, Json.encodeToString(work), token, owner, until, work.id))
    }
    fun claim(id: String, owner: String, action: OperationWorkAction, now: Long, leaseMilliseconds: Long = 30_000): OperationWorkClaimResult {
        check(db.inTransaction()); require(UUID.fromString(owner).toString().uppercase() == owner && leaseMilliseconds > 0 && now >= 0 && now <= Long.MAX_VALUE - leaseMilliseconds)
        val work = read(id) ?: return OperationWorkClaimResult.Unavailable
        if (!db.rawQuery("SELECT 1 FROM operation_work w WHERE id=? AND $runnable", arrayOf(id)).use { it.moveToFirst() }) return OperationWorkClaimResult.Unavailable
        // Never reclaim on a clock alone, including an expired claim held by the same owner.
        return when (val decision = OperationWorkClaimPolicy.claim(work, action, now)) {
            OperationWorkClaimPolicy.Decision.Unavailable -> {
                if (!work.terminal && work.scheduling != OperationSchedulingState.Claimed && work.submissionStarted && action == OperationWorkAction.Submit && work.admissionDeadline?.let { it <= now } == true)
                    put(work.copy(nextAction = OperationWorkAction.Reconcile, revision = Math.addExact(work.revision, 1)))
                OperationWorkClaimResult.Unavailable
            }
            is OperationWorkClaimPolicy.Decision.ExpiredUnsubmitted -> { put(decision.work); OperationWorkClaimResult.ExpiredUnsubmitted }
            is OperationWorkClaimPolicy.Decision.NeedsAttention -> { put(decision.work); OperationWorkClaimResult.NeedsAttention }
            is OperationWorkClaimPolicy.Decision.Claimed -> {
                val token = UUID.randomUUID().toString().uppercase()
                put(decision.work, token, owner, now + leaseMilliseconds)
                OperationWorkClaimResult.Claimed(OperationWorkClaim(decision.work, decision.action, owner, token))
            }
        }
    }
    fun matches(claim: OperationWorkClaim): Boolean = db.rawQuery(
        "SELECT 1 FROM operation_work WHERE id=? AND claim_id=? AND claim_owner=? AND revision=? AND scheduling='Claimed'",
        arrayOf(claim.work.id, claim.token, claim.owner, claim.work.revision.toString())).use { it.moveToFirst() }
    fun defer(claim: OperationWorkClaim, until: Long, code: String, scheduling: OperationSchedulingState,
        nextAction: OperationWorkAction = OperationWorkAction.Reconcile, processing: Boolean = false): OperationWork {
        check(db.inTransaction()); require(until >= 0 && code.isNotEmpty() && code.toByteArray().size <= 128)
        require(scheduling in setOf(OperationSchedulingState.BackingOff, OperationSchedulingState.WaitingForNetwork,
            OperationSchedulingState.WaitingForAuthentication, OperationSchedulingState.NeedsAttention, OperationSchedulingState.Suspended))
        val work = requireNotNull(read(claim.work.id))
        if (work.terminal) return work
        if (!matches(claim)) throw StaleOperationClaim()
        return work.copy(execution = if (processing || work.execution == OperationExecutionState.Processing) OperationExecutionState.Processing else OperationExecutionState.AwaitingConfirmation,
            scheduling = scheduling, nextAction = nextAction, nextActionAt = until, lastErrorCode = code, revision = Math.addExact(work.revision, 1)).also { put(it) }
    }
    /** Caller has drained the old physical domain steps. An owner change is not inferred from time. */
    fun recoverForDrainedOwner(owner: String, now: Long, kinds: PersistentSet<OperationKind>, recovered: (OperationWork) -> Unit) {
        check(db.inTransaction()); require(UUID.fromString(owner).toString().uppercase() == owner && now >= 0)
        if (kinds.isEmpty()) return
        val filter = kinds.joinToString(",", "(", ")") { "?" }
        var after = 0L
        while (true) {
            val ids = db.rawQuery("SELECT id,sequence FROM operation_work WHERE scheduling='Claimed' AND claim_owner<>? AND sequence>? AND kind IN $filter ORDER BY sequence LIMIT 64",
                (listOf(owner, after.toString()) + kinds.map { it.name }).toTypedArray()).use { rows -> buildList { while (rows.moveToNext()) add(rows.getString(0) to rows.getLong(1)) } }
            if (ids.isEmpty()) break
            ids.forEach { (id, _) ->
                val old = requireNotNull(read(id))
                val next = old.copy(execution = if (old.execution == OperationExecutionState.Processing) old.execution else OperationExecutionState.AwaitingConfirmation,
                    scheduling = OperationSchedulingState.Ready, nextAction = OperationWorkAction.Reconcile, nextActionAt = now,
                    lastErrorCode = "PROCESS_INTERRUPTED", revision = Math.addExact(old.revision, 1))
                put(next); recovered(next)
            }
            after = ids.last().second
        }
    }
    /** Only the domain adapter can call this after validating and canonicalizing its receipt. */
    fun complete(id: String, fingerprint: String, execution: OperationExecutionState, canonicalReceipt: String, now: Long): OperationWork {
        check(db.inTransaction()); require(now >= 0 && execution in setOf(OperationExecutionState.Committed, OperationExecutionState.Rejected, OperationExecutionState.Conflicted, OperationExecutionState.Closed))
        val bytes = canonicalReceipt.toByteArray(); require(bytes.size in 1..65_536)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val work = requireNotNull(read(id)); require(work.fingerprint == fingerprint)
        if (work.terminal) {
            require(work.execution == execution && db.rawQuery("SELECT receipt_digest FROM operation_work WHERE id=?", arrayOf(id)).use { it.moveToFirst() && it.getString(0) == digest })
            return work
        }
        require(work.submissionStarted)
        val next = work.copy(execution = execution, scheduling = OperationSchedulingState.Finished, completedAt = now,
            lastErrorCode = null, revision = Math.addExact(work.revision, 1))
        put(next); db.execSQL("UPDATE operation_work SET receipt_digest=? WHERE id=?", arrayOf(digest, id)); return next
    }
    fun cancel(id: String, now: Long): OperationWork {
        check(db.inTransaction()); require(now >= 0)
        val work = requireNotNull(read(id))
        if (work.execution == OperationExecutionState.CancelledLocally) return work
        require(!work.submissionStarted && !work.terminal)
        return work.copy(execution = OperationExecutionState.CancelledLocally, scheduling = OperationSchedulingState.Finished,
            completedAt = now, revision = Math.addExact(work.revision, 1)).also { put(it) }
    }
    fun retry(id: String, now: Long, resetRounds: Boolean): OperationWork {
        check(db.inTransaction()); require(now >= 0)
        val work = requireNotNull(read(id)); require(!work.terminal && work.scheduling != OperationSchedulingState.Claimed)
        return work.copy(scheduling = OperationSchedulingState.Ready, nextActionAt = maxOf(work.nextActionAt, now),
            submissionRoundAttempts = if (resetRounds) 0 else work.submissionRoundAttempts,
            reconciliationRoundAttempts = if (resetRounds) 0 else work.reconciliationRoundAttempts,
            submissionRoundDeadline = if (resetRounds) null else work.submissionRoundDeadline,
            reconciliationRoundDeadline = if (resetRounds) null else work.reconciliationRoundDeadline,
            nextAction = if (resetRounds) { if (work.submissionStarted) OperationWorkAction.Reconcile else OperationWorkAction.Submit } else work.nextAction,
            revision = Math.addExact(work.revision, 1)).also { put(it) }
    }
    /** Compatibility adapter updates are accepted only without an active physical claim. */
    fun synchronize(value: OperationWork) {
        check(db.inTransaction()); val old = requireNotNull(read(value.id))
        require(old.scheduling != OperationSchedulingState.Claimed && old.fingerprint == value.fingerprint && !old.terminal)
        require(old.actor == value.actor && old.kind == value.kind && old.identityKey == value.identityKey &&
            old.orderingKey == value.orderingKey && old.admissionDeadline == value.admissionDeadline)
        require(!old.submissionStarted || value.submissionStarted)
        put(value.copy(localSequence = old.localSequence, revision = Math.addExact(old.revision, 1), originalCreatedAt = old.originalCreatedAt))
    }
}
