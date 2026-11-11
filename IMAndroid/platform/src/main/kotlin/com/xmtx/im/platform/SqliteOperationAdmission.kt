package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Incremental reservation projection in the SAME transaction as domain writes.
 * Triggers enqueue keys only; they never copy commands or require SQLite JSON extensions.
 * Reconcile after all domain writes so proposal-to-command transfers do not double count.
 * This is admission accounting, not an execution claim or permission to submit a command.
 */
internal class SqliteOperationAdmission(private val db: SQLiteDatabase, private val account: UserId,
    private val limits: OperationAdmissionLimits) {
    private data class Source(val table: String, val column: String, val domain: OperationAdmissionDomain, val key: String = "id")
    private data class Reservation(val bytes: Long, val control: Boolean = false)
    private val sources = listOf(
        Source("direct_operations", "work", OperationAdmissionDomain.DirectRoom),
        Source("social_proposals", "proposal", OperationAdmissionDomain.SocialProposal),
        Source("social_operations", "work", OperationAdmissionDomain.Social),
        Source("membership_operations", "work", OperationAdmissionDomain.Membership),
        Source("administration_operations", "work", OperationAdmissionDomain.Administration),
        Source("invitation_operations", "work", OperationAdmissionDomain.Invitation),
        Source("capability_operations", "work", OperationAdmissionDomain.GroupCapability),
        Source("preference_operations", "work", OperationAdmissionDomain.AccountPreference),
        Source("message_moderation_operations", "work", OperationAdmissionDomain.Moderation),
        Source("read_intents", "sequence", OperationAdmissionDomain.ReadIntent, "room"),
        Source("read_operations", "work", OperationAdmissionDomain.ReadOperation),
        Source("group_creations", "work", OperationAdmissionDomain.GroupCreation),
        Source("forward_operations", "work", OperationAdmissionDomain.ForwardPlan),
        Source("personal_operations", "work", OperationAdmissionDomain.PersonalPreference),
        Source("message_mutations", "work", OperationAdmissionDomain.MessageMutation),
        Source("reaction_operations", "work", OperationAdmissionDomain.MessageReaction),
        Source("send_intents", "payload", OperationAdmissionDomain.SendPreparation),
        Source("outbox", "command", OperationAdmissionDomain.MessageSend),
        Source("profile_intents", "payload", OperationAdmissionDomain.ProfilePreparation),
        Source("own_profile_operations", "work", OperationAdmissionDomain.OwnProfile),
        Source("name_operations", "work", OperationAdmissionDomain.Name),
    ).associateBy { it.table }
    private val sends = SqliteSendAdmission(db, account)

    init { if (!db.isReadOnly) {
        check(db.inTransaction())
        db.execSQL("CREATE TABLE IF NOT EXISTS operation_reservations (source TEXT NOT NULL,id TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(typeof(bytes)='integer' AND bytes>0),PRIMARY KEY(source,id))")
        val columns = db.rawQuery("PRAGMA table_info(operation_reservations)", null).use { rows ->
            buildSet { while (rows.moveToNext()) add(rows.getString(1)) }
        }
        if ("control" !in columns) db.execSQL("ALTER TABLE operation_reservations ADD COLUMN control INTEGER NOT NULL DEFAULT 0 CHECK(control IN(0,1))")
        db.execSQL("CREATE TABLE IF NOT EXISTS operation_reservation_dirty (source TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(source,id))")
        db.execSQL("CREATE TABLE IF NOT EXISTS operation_reservation_versions (source TEXT PRIMARY KEY,version INTEGER NOT NULL)")
        // A frozen profile work owns the complete linked intent payload after handoff.
        for ((event, row) in listOf("INSERT" to "NEW", "UPDATE" to "NEW", "DELETE" to "OLD"))
            db.execSQL("CREATE TRIGGER IF NOT EXISTS operation_profile_work_$event AFTER $event ON profile_intents BEGIN INSERT OR IGNORE INTO operation_reservation_dirty VALUES ('own_profile_operations',$row.operation); END")
        for (source in sources.values) {
            // Frozen send bytes never change through the SDK. Only semantic state changes
            // invalidate their reservation; reading a bounded page must not decode other rows.
            if (source.domain == OperationAdmissionDomain.MessageSend)
                db.execSQL("DROP TRIGGER IF EXISTS operation_reservation_outbox_UPDATE")
            for ((event, row) in listOf("INSERT" to "NEW", "UPDATE" to "NEW", "DELETE" to "OLD")) {
                val change = if (source.domain == OperationAdmissionDomain.MessageSend && event == "UPDATE")
                    "UPDATE OF receipt,send_work,accepted_projection_observed" else event
                db.execSQL("CREATE TRIGGER IF NOT EXISTS operation_reservation_${source.table}_$event AFTER $change ON ${source.table} BEGIN INSERT OR IGNORE INTO operation_reservation_dirty VALUES ('${source.table}',$row.${source.key}); END")
            }
            // One-time streaming migration. Existing over-limit work remains recoverable.
            if (!db.rawQuery("SELECT 1 FROM operation_reservation_versions WHERE source=? AND version=1", arrayOf(source.table)).use { it.moveToFirst() }) {
                db.execSQL("INSERT OR IGNORE INTO operation_reservation_dirty SELECT ?,${source.key} FROM ${source.table}", arrayOf(source.table))
                db.execSQL("INSERT OR REPLACE INTO operation_reservation_versions VALUES (?,1)", arrayOf(source.table))
            }
        }
        reconcile(enforce = false)
    } }

    fun usage(): OperationAdmissionUsage = db.rawQuery("""
        SELECT COALESCE(SUM(CASE WHEN control=0 THEN 1 ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN control=0 THEN bytes ELSE 0 END),0),
            COALESCE(SUM(control),0),COALESCE(SUM(CASE WHEN control=1 THEN bytes ELSE 0 END),0)
        FROM operation_reservations
    """.trimIndent(), null).use {
        check(it.moveToFirst())
        OperationAdmissionUsage(it.getLong(0), it.getLong(1), sources.values.map { source -> source.domain }.toPersistentSet(), it.getLong(2), it.getLong(3))
    }

    /** Called before a control-to-ordinary transfer, inside the same transaction. */
    fun canAdmitOrdinary(bytes: Long): Boolean {
        check(db.inTransaction()); require(bytes > 0)
        val current = usage()
        return current.activeCount < limits.maximumActiveCount && current.reservedBytes <= limits.maximumReservedBytes &&
            bytes <= limits.maximumReservedBytes - current.reservedBytes
    }

    fun reconcile(enforce: Boolean = true) {
        check(db.inTransaction())
        if (!db.rawQuery("SELECT 1 FROM operation_reservation_dirty LIMIT 1", null).use { it.moveToFirst() }) return
        val before = usage()
        while (true) {
            val batch = db.rawQuery("SELECT source,id FROM operation_reservation_dirty ORDER BY source,id LIMIT 128", null).use { rows ->
                buildList { while (rows.moveToNext()) add(rows.getString(0) to rows.getString(1)) }
            }
            if (batch.isEmpty()) break
            for ((table, id) in batch) {
                val source = requireNotNull(sources[table]) { "Unknown operation reservation source" }
                val reservation = if (source.domain == OperationAdmissionDomain.MessageSend) sends.reservation(id)?.let { Reservation(it) }
                else db.rawQuery("SELECT ${source.column} FROM ${source.table} WHERE ${source.key}=?", arrayOf(id)).use {
                    if (it.moveToFirst()) record(source.domain, id, it.getString(0)) else null
                }
                if (reservation == null) db.execSQL("DELETE FROM operation_reservations WHERE source=? AND id=?", arrayOf(table, id))
                else {
                    require(reservation.bytes > 0)
                    db.execSQL("INSERT OR REPLACE INTO operation_reservations(source,id,bytes,control) VALUES (?,?,?,?)", arrayOf<Any>(table, id, reservation.bytes, if(reservation.control) 1 else 0))
                }
                db.execSQL("DELETE FROM operation_reservation_dirty WHERE source=? AND id=?", arrayOf(table, id))
            }
        }
        val after = usage()
        // Legacy overages may finish, retry, or transfer without growing either dimension.
        // Failure rolls back business data, reservations and dirty keys together.
        if (enforce && ((after.activeCount > limits.maximumActiveCount && after.activeCount > before.activeCount) ||
                    (after.reservedBytes > limits.maximumReservedBytes && after.reservedBytes > before.reservedBytes) ||
                    (after.controlCount > 64 && after.controlCount > before.controlCount) ||
                    (after.controlReservedBytes > 1_048_576 && after.controlReservedBytes > before.controlReservedBytes)))
            throw OperationCapacityExceeded()
    }

    private fun record(domain: OperationAdmissionDomain, id: String, value: String): Reservation? {
        if (domain == OperationAdmissionDomain.ReadOperation) {
            val work = Json.decodeFromString<ReadWork>(value)
            require(work.command.actor == account && work.command.operation == id)
            if (!work.active) return null
            val bytes = work.command.payload().toString().utf8Bytes()
            require(bytes <= 4_096)
            return Reservation(bytes + if(work.control) 67_584 else 0, work.control)
        }
        return reservation(domain, id, value)?.let { Reservation(it) }
    }

    private fun reservation(domain: OperationAdmissionDomain, id: String, value: String): Long? = when (domain) {
        OperationAdmissionDomain.ProfilePreparation -> Json.decodeFromString<ProfileIntent>(value).let {
            require(it.actor == account && it.id == id)
            if (it.frozen || it.locallyTerminal) null else {
                val frozen = it.copy(frozen = true, preparation = ProfilePreparation.Pending)
                // Scheduling issues do not alter the admitted business payload.
                maxOf(Json.encodeToString(it.copy(preparation = ProfilePreparation.Pending)).utf8Bytes(),
                    Json.encodeToString(frozen).utf8Bytes(), Json.encodeToString(frozen.command()).utf8Bytes())
            }
        }
        OperationAdmissionDomain.OwnProfile -> Json.decodeFromString<OwnProfileWork>(value).let { work ->
            require(work.command.actor == account && work.command.operation == id)
            if (work.terminal) null else {
                val commandBytes = Json.encodeToString(work.command).utf8Bytes()
                db.rawQuery("SELECT payload FROM profile_intents WHERE operation=?", arrayOf(id)).use { rows ->
                    if (!rows.moveToFirst()) commandBytes else {
                        val intent = Json.decodeFromString<ProfileIntent>(rows.getString(0))
                        require(intent.actor == account && intent.frozen && intent.command() == work.command)
                        maxOf(commandBytes, Json.encodeToString(intent).utf8Bytes())
                    }
                }
            }
        }
        OperationAdmissionDomain.Name -> Json.decodeFromString<NameWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            if (it.terminal) null else Json.encodeToString(it.command).utf8Bytes()
        }
        OperationAdmissionDomain.SendPreparation -> Json.decodeFromString<SendIntent>(value).let {
            require(it.actor == account && it.id == id)
            if (it.preparation !in setOf(SendPreparation.Preparing, SendPreparation.NeedsAttention)) null else {
                // Reserve the future protobuf envelope, including the largest possible deadline varint.
                val command = if (it.mediaIds.isEmpty()) MessageCommand.text(account, it.room, it.text, Long.MAX_VALUE, it.operation, it.rich)
                    else MessageCommand.withMedia(account, it.room, it.text, it.mediaIds, Long.MAX_VALUE, it.operation, it.rich)
                command.serializedSize.toLong() + 256
            }
        }
        OperationAdmissionDomain.MessageSend -> error("Send reservations require durable receipt and projection evidence")
        OperationAdmissionDomain.PersonalPreference -> Json.decodeFromString<PersonalWork>(value).let {
            require(it.actor == account && it.operation == id)
            if (it.terminal) null else {
                // Reserve the largest revision encoding while the target is still coalescible.
                val command = it.command ?: PersonalCommand(it.actor, it.operation, it.target, Long.MAX_VALUE - 1, it.deadline)
                val frozen = Json.encodeToString(command).utf8Bytes()
                if (it.command != null) frozen else maxOf(frozen, Json.encodeToString(it.target).utf8Bytes())
            }
        }
        OperationAdmissionDomain.MessageMutation -> Json.decodeFromString<MessageMutationWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            if (it.terminal) null else Json.encodeToString(it.command).utf8Bytes()
        }
        OperationAdmissionDomain.MessageReaction -> Json.decodeFromString<ReactionWork>(value).let {
            require(it.intent.actor == account && it.intent.operation == id)
            if (it.terminal) null else (it.command ?: ReactionCommand(it.intent, Long.MAX_VALUE - 1)).payload().toString().utf8Bytes()
        }
        OperationAdmissionDomain.GroupCreation -> Json.decodeFromString<GroupCreationWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            if (it.terminal) null else {
                // Count the Codable member array without allocating another full audience list.
                val audience = 2L + (it.command.members.size - 1).coerceAtLeast(0) + it.command.members.sumOf { member ->
                    buildJsonObject { put("rawValue", member.value) }.toString().utf8Bytes()
                }
                it.command.payload().toString().utf8Bytes() + audience + 4_096 + 65_536
            }
        }
        OperationAdmissionDomain.ForwardPlan -> Json.decodeFromString<ForwardWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            // Reserve progress proof and terminal receipt before the first physical request.
            if (it.terminal) null else it.command.payload().toString().utf8Bytes() + 1_048_576 + 65_536
        }
        OperationAdmissionDomain.ReadIntent -> {
            // All UUIDs have the same encoded length; this placeholder never becomes a command.
            ReadCommand(account, RoomId(id), "00000000-0000-0000-0000-000000000000", value.toLong()).payload().toString().utf8Bytes()
        }
        OperationAdmissionDomain.ReadOperation -> error("Read operations require pool classification")
        OperationAdmissionDomain.DirectRoom -> Json.decodeFromString<DirectRoomWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            if (it.terminal) null else 65_536L + it.command.payload().toString().utf8Bytes() +
                (it.publicIdentity?.let { identity -> Json.encodeToString(identity).utf8Bytes() } ?: 0)
        }
        OperationAdmissionDomain.SocialProposal -> Json.decodeFromString<SocialProposal>(value).let {
            require(it.actor == account && it.id == id); 73_728L
        }
        OperationAdmissionDomain.Social -> Json.decodeFromString<SocialWork>(value).let {
            require(it.command.actor == account && it.command.operation == id)
            // All Android social commands originate from a persisted proposal.
            if (it.terminal) null else 73_728L
        }
        OperationAdmissionDomain.Membership -> Json.decodeFromString<MembershipWork>(value).let {
            require(it.intent.actor == account && it.intent.operation == id)
            if (it.terminal) null else 73_728L
        }
        OperationAdmissionDomain.Administration -> Json.decodeFromString<AdministrationWork>(value).let {
            require(it.intent.actor == account && it.intent.key == id)
            if (it.terminal) null else 73_728L
        }
        OperationAdmissionDomain.Invitation -> Json.decodeFromString<InvitationWork>(value).let {
            require(it.intent.actor == account && it.intent.key == id)
            if (it.terminal) null else 81_920L
        }
        OperationAdmissionDomain.GroupCapability -> Json.decodeFromString<GroupCapabilityWork>(value).let {
            require(it.intent.actor == account && it.intent.operation == id)
            if (it.terminal) null else 131_072L
        }
        OperationAdmissionDomain.AccountPreference -> Json.decodeFromString<PreferenceWork>(value).let {
            require(it.actor == account && it.operation == id)
            if (it.terminal) null else 73_728L
        }
        OperationAdmissionDomain.Moderation -> Json.decodeFromString<ModerationWork>(value).let {
            require(it.intent.actor == account && it.intent.key == id)
            if (it.terminal) null else 73_728L
        }
    }
    private fun String.utf8Bytes(): Long = toByteArray(Charsets.UTF_8).size.toLong()
}
