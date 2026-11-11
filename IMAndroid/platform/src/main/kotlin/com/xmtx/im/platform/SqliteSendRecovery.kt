package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperation
import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperationReceipt
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** All methods run under the account store's transaction. Leases fence competing or late workers. */
internal class SqliteSendRecovery(private val db: SQLiteDatabase,private val actor: UserId,private val revoked: (String)->Boolean) {
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(outbox)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        for((column,type) in listOf("send_work" to "TEXT","send_due" to "INTEGER NOT NULL DEFAULT 0","send_paused" to "INTEGER NOT NULL DEFAULT 0","send_token" to "TEXT","send_lease" to "INTEGER NOT NULL DEFAULT 0","send_terminal" to "INTEGER NOT NULL DEFAULT 0","send_waiting" to "INTEGER NOT NULL DEFAULT 0"))
            if(column !in columns) db.execSQL("ALTER TABLE outbox ADD COLUMN $column $type")
        db.execSQL("CREATE INDEX IF NOT EXISTS outbox_send_due ON outbox(send_paused,send_due) WHERE receipt IS NULL")
        db.execSQL("CREATE INDEX IF NOT EXISTS outbox_send_waiting ON outbox(send_paused) WHERE receipt IS NULL AND send_waiting>0")
    } }
    fun claim(now: Long): SendAttempt? {
        require(now>=0 && now<Long.MAX_VALUE-60_000)
        repeat(32) {
            val selected=db.rawQuery("""
                SELECT o.id,o.command,o.send_work FROM outbox o
                WHERE o.receipt IS NULL AND o.send_paused=0 AND o.send_due<=? AND o.send_lease<=?
                  AND NOT EXISTS(SELECT 1 FROM abandoned_text_sends a WHERE a.operation=o.id)
                  AND NOT EXISTS(SELECT 1 FROM memberships m WHERE m.room=o.room AND m.member=0)
                AND NOT EXISTS(SELECT 1 FROM outbox earlier WHERE earlier.room=o.room AND earlier.rowid<o.rowid AND earlier.receipt IS NULL AND earlier.send_terminal=0)
                ORDER BY o.send_due,o.rowid LIMIT 1
            """.trimIndent(),arrayOf(now.toString(),now.toString())).use {rows->
                if(!rows.moveToFirst()) null else Triple(rows.getString(0),MessageSendOperation.parseFrom(rows.getBlob(1)),if(rows.isNull(2)) SendRecovery.Legacy else Json.decodeFromString<SendRecovery>(rows.getString(2)))
            } ?: return null
            val (operation,command,prior)=selected
            require(command.clientMessageId==operation && command.senderUserId==actor.value)
            when(val decision=SendRecoveryPolicy.claim(prior,now,command.firstSubmissionDeadlineMs)) {
                SendClaimDecision.Wait->return null
                is SendClaimDecision.Stop->save(operation,decision.state)
                is SendClaimDecision.Ready->{
                    val token=UUID.randomUUID().toString();save(operation,decision.state,token,now+SendRecoveryPolicy.LEASE_MILLISECONDS)
                    return SendAttempt(command,token,decision.action,decision.state,isRetry=prior.submitted)
                }
            }
        }
        return null
    }
    fun matches(attempt: SendAttempt)=db.rawQuery("SELECT command FROM outbox WHERE id=? AND send_token=? AND receipt IS NULL",arrayOf(attempt.command.clientMessageId,attempt.token)).use {it.moveToFirst() && MessageSendOperation.parseFrom(it.getBlob(0))==attempt.command} && !revoked(attempt.command.roomId)
    fun observe(attempt:SendAttempt,now:Long):OperationStepObservation? {
        require(attempt.command.senderUserId==actor.value && now>=0)
        if(revoked(attempt.command.roomId)) return null
        return db.rawQuery("SELECT command,receipt,send_work,send_token,send_lease,EXISTS(SELECT 1 FROM abandoned_text_sends a WHERE a.operation=outbox.id) FROM outbox WHERE id=?",arrayOf(attempt.command.clientMessageId)).use {rows->
            if(!rows.moveToFirst() || MessageSendOperation.parseFrom(rows.getBlob(0))!=attempt.command) return@use null
            if(!rows.isNull(1)) {
                val receipt=MessageSendOperationReceipt.parseFrom(rows.getBlob(1));validateSendReceipt(attempt.command,receipt)
                val state=when {receipt.hasAccepted()->OperationExecutionState.Committed
                    receipt.hasRejected()->OperationExecutionState.Rejected;else->OperationExecutionState.Closed}
                OperationStepObservation(state,OperationSchedulingState.Finished)
            } else if(rows.getInt(5)!=0) {
                OperationStepObservation(OperationExecutionState.CancelledLocally,OperationSchedulingState.Finished)
            } else {
                val state=if(rows.isNull(2)) SendRecovery.Legacy else Json.decodeFromString<SendRecovery>(rows.getString(2))
                state.operationObservation(now,claimed=!rows.isNull(3) && rows.getLong(4)>now)
            }
        }
    }
    fun defer(attempt: SendAttempt,state: SendRecovery) {
        require(state.submitted && state.nextAt>=0 && state.submitAttempts>=attempt.state.submitAttempts && state.recoveryAttempts>=attempt.state.recoveryAttempts && state.status!=SendRecoveryStatus.ExpiredUnsubmitted)
        if(matches(attempt)) save(attempt.command.clientMessageId,state)
    }
    fun resume(room: RoomId,viewer: UserId,operation: String,now: Long) {
        require(viewer==actor && !revoked(room.value))
        val state=db.rawQuery("SELECT send_work FROM outbox WHERE id=? AND room=? AND receipt IS NULL AND send_paused=1",arrayOf(operation,room.value)).use {
            if(it.moveToFirst() && !it.isNull(0)) Json.decodeFromString<SendRecovery>(it.getString(0)) else null
        } ?: return
        if(state.status!=SendRecoveryStatus.NeedsAttention) return
        save(operation,SendRecoveryPolicy.resume(state,now))
    }
    fun connected(viewer: UserId,now: Long) {
        require(viewer==actor && now>=0)
        var after=0L
        while(true) {
            val batch=db.rawQuery("""
                SELECT o.rowid,o.id,o.send_work FROM outbox o
                WHERE o.receipt IS NULL AND o.send_paused=1 AND o.send_waiting>0 AND o.rowid>?
                  AND NOT EXISTS(SELECT 1 FROM memberships m WHERE m.room=o.room AND m.member=0)
                ORDER BY o.rowid LIMIT 64
            """.trimIndent(),arrayOf(after.toString())).use {rows->buildList {while(rows.moveToNext()) {
                add(Triple(rows.getLong(0),rows.getString(1),Json.decodeFromString<SendRecovery>(rows.getString(2))))
            }}}
            if(batch.isEmpty()) return
            batch.forEach {(_,operation,state)->save(operation,SendRecoveryPolicy.connected(state,now))}
            after=batch.last().first
        }
    }
    private fun save(operation: String,state: SendRecovery,token: String?=null,lease: Long=0) {
        val waiting=when(state.status) {SendRecoveryStatus.WaitingForNetwork->1;SendRecoveryStatus.WaitingForAuthentication->2;else->0}
        db.execSQL("UPDATE outbox SET send_work=?,send_due=?,send_paused=?,send_token=?,send_lease=?,send_terminal=?,send_waiting=? WHERE id=? AND receipt IS NULL",arrayOf<Any?>(Json.encodeToString(state),state.nextAt,
            if(waiting>0 || state.status in setOf(SendRecoveryStatus.NeedsAttention,SendRecoveryStatus.ExpiredUnsubmitted)) 1 else 0,token,lease,if(state.status==SendRecoveryStatus.ExpiredUnsubmitted) 1 else 0,waiting,operation))
    }
}
