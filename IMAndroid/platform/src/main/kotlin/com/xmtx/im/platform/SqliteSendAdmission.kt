package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperation
import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperationReceipt
import kotlinx.serialization.json.Json

/** Acceptance alone cannot free a send reservation. Projection evidence is transactional and monotonic. */
internal class SqliteSendAdmission(private val db: SQLiteDatabase, private val actor: UserId) {
    init { if (!db.isReadOnly) {
        check(db.inTransaction())
        val columns = db.rawQuery("PRAGMA table_info(outbox)", null).use { rows ->
            buildSet { while (rows.moveToNext()) add(rows.getString(1)) }
        }
        if ("accepted_projection_observed" !in columns) db.execSQL("ALTER TABLE outbox ADD COLUMN accepted_projection_observed INTEGER NOT NULL DEFAULT 0 CHECK(accepted_projection_observed IN(0,1))")
        db.execSQL("CREATE INDEX IF NOT EXISTS outbox_waiting_projection ON outbox(room,echo_message) WHERE receipt IS NOT NULL AND accepted_projection_observed=0")
        for (table in listOf("messages", "message_tombstones")) for (event in listOf("INSERT", "UPDATE")) {
            // The ledger table is installed before any domain write can fire these triggers.
            db.execSQL("""
                CREATE TRIGGER IF NOT EXISTS operation_send_projection_${table}_$event AFTER $event ON $table
                BEGIN INSERT OR IGNORE INTO operation_reservation_dirty
                    SELECT 'outbox',id FROM outbox WHERE room=NEW.room AND echo_message=NEW.id
                        AND receipt IS NOT NULL AND accepted_projection_observed=0; END
            """.trimIndent())
        }
    } }

    fun reservation(id: String): Long? = db.rawQuery(
        "SELECT command,receipt,send_work,accepted_projection_observed FROM outbox WHERE id=?", arrayOf(id)
    ).use { rows ->
        if (!rows.moveToFirst()) return@use null
        val command = MessageSendOperation.parseFrom(rows.getBlob(0))
        require(command.clientMessageId == id && command.senderUserId == actor.value)
        if (!rows.isNull(1)) {
            val receipt = MessageSendOperationReceipt.parseFrom(rows.getBlob(1))
            validateSendReceipt(command, receipt)
            if (receipt.hasRejected()) return@use null
            if (rows.getInt(3) != 0) return@use null
            val accepted = receipt.accepted
            val observed = db.rawQuery("""
                SELECT 1 FROM messages WHERE id=? AND room=? AND accepted_sequence=?
                UNION ALL SELECT 1 FROM message_tombstones WHERE id=? AND room=? LIMIT 1
            """.trimIndent(), arrayOf(accepted.messageId, command.roomId, accepted.roomSequence.toString(), accepted.messageId, command.roomId)).use { it.moveToFirst() }
            if (observed) {
                db.execSQL("UPDATE outbox SET accepted_projection_observed=1 WHERE id=?", arrayOf(id))
                return@use null
            }
        } else {
            val recovery = if (rows.isNull(2)) SendRecovery.Legacy else Json.decodeFromString<SendRecovery>(rows.getString(2))
            if (!recovery.submitted && recovery.status == SendRecoveryStatus.ExpiredUnsubmitted) return@use null
        }
        command.serializedSize.toLong() + 256
    }
}
