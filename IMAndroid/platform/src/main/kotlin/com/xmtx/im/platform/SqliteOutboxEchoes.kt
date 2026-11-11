package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Frozen commands remain authoritative; indexed routing columns are maintained in the same transaction. */
internal class SqliteOutboxEchoes(private val db: SQLiteDatabase,private val actor: UserId,private val revoked: (String)->Boolean) {
    private val historyScope=java.util.UUID.randomUUID().toString()
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS text_send_replacements(original TEXT PRIMARY KEY,replacement TEXT UNIQUE NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS abandoned_text_sends(operation TEXT PRIMARY KEY)")
        val columns=db.rawQuery("PRAGMA table_info(outbox)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("room" !in columns) db.execSQL("ALTER TABLE outbox ADD COLUMN room TEXT")
        if("echo_message" !in columns) db.execSQL("ALTER TABLE outbox ADD COLUMN echo_message TEXT")
        if("echo_created" !in columns) db.execSQL("ALTER TABLE outbox ADD COLUMN echo_created INTEGER")
        db.rawQuery("SELECT id,command,receipt FROM outbox WHERE room IS NULL OR echo_message IS NULL OR echo_created IS NULL",null).use {rows->while(rows.moveToNext()) {
            val command=MessageSendOperation.parseFrom(rows.getBlob(1));val receipt=if(rows.isNull(2)) null else MessageSendOperationReceipt.parseFrom(rows.getBlob(2))
            require(command.clientMessageId==rows.getString(0) && command.senderUserId==actor.value)
            db.execSQL("UPDATE outbox SET room=?,echo_message=?,echo_created=? WHERE id=?",arrayOf<Any>(command.roomId,echoId(command,receipt),created(command),command.clientMessageId))
        }}
        db.execSQL("CREATE INDEX IF NOT EXISTS outbox_room_tail ON outbox(room)")
        db.execSQL("CREATE INDEX IF NOT EXISTS outbox_room_preview ON outbox(room,echo_created DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS messages_room_preview ON messages(room,time DESC,sequence,id)")
    } }
    fun enqueue(command: MessageSendOperation) {
        require(command.senderUserId==actor.value)
        db.execSQL("INSERT INTO outbox(id,command,room,echo_message,echo_created,send_work) VALUES (?,?,?,?,?,?)",arrayOf<Any>(command.clientMessageId,command.toByteArray(),command.roomId,command.clientMessageId,created(command),Json.encodeToString(SendRecovery())))
    }
    fun complete(operation: String,receipt: MessageSendOperationReceipt) {
        db.rawQuery("SELECT command,receipt FROM outbox WHERE id=?", arrayOf(operation)).use { rows ->
            require(rows.moveToFirst()) { "Unknown send operation" }
            val command = MessageSendOperation.parseFrom(rows.getBlob(0))
            require(command.clientMessageId == operation && command.senderUserId == actor.value)
            validateSendReceipt(command, receipt)
            if (!rows.isNull(1)) require(MessageSendOperationReceipt.parseFrom(rows.getBlob(1)) == receipt) { "发送结果不能被覆盖" }
        }
        db.execSQL("UPDATE outbox SET receipt=?,echo_message=? WHERE id=?",arrayOf(receipt.toByteArray(),if(receipt.hasAccepted()) receipt.accepted.messageId else operation,operation))
    }
    private fun provenUnsent(command: MessageSendOperation,receipt: MessageSendOperationReceipt?,recovery: SendRecovery): Boolean {
        if(receipt!=null) {
            validateSendReceipt(command,receipt)
            return receipt.hasRejected()
        }
        return !recovery.submitted && recovery.status==SendRecoveryStatus.ExpiredUnsubmitted
    }
    private fun requireUnsentText(room: RoomId,viewer: UserId,operation: String): MessageSendOperation {
        require(viewer==actor && !revoked(room.value))
        val command=db.rawQuery("SELECT command,receipt,send_work FROM outbox WHERE id=? AND room=?",arrayOf(operation,room.value)).use {rows->
            check(rows.moveToFirst()) {"发送记录已不可用"}
            val frozen=MessageSendOperation.parseFrom(rows.getBlob(0))
            require(frozen.senderUserId==actor.value && frozen.roomId==room.value && frozen.clientMessageId==operation)
            val receipt=if(rows.isNull(1)) null else MessageSendOperationReceipt.parseFrom(rows.getBlob(1))
            val recovery=if(rows.isNull(2)) SendRecovery.Legacy else Json.decodeFromString<SendRecovery>(rows.getString(2))
            check(provenUnsent(frozen,receipt,recovery)) {"原消息尚未确认未发送，请先继续确认"}
            require(frozen.mediaIdsCount==0 && frozen.text.isNotBlank())
            frozen
        }
        check(!db.rawQuery("SELECT 1 FROM send_intents WHERE operation=?",arrayOf(operation)).use {it.moveToFirst()}) {"请从附件准备任务处理此消息"}
        return command
    }
    /** Caller holds the account transaction; neither unknown outcomes nor media may bypass their owner. */
    fun replaceText(room: RoomId,viewer: UserId,operation: String,now: Long): String {
        require(now>=0 && now<Long.MAX_VALUE-ClientSubmissionWindow.COMMAND_MILLISECONDS)
        val command=requireUnsentText(room,viewer,operation)
        check(!db.rawQuery("SELECT 1 FROM abandoned_text_sends WHERE operation=?",arrayOf(operation)).use {it.moveToFirst()}) {"此发送记录已放弃"}
        db.rawQuery("SELECT replacement FROM text_send_replacements WHERE original=?",arrayOf(operation)).use {if(it.moveToFirst()) return it.getString(0)}
        val next=MessageCommand.text(actor,room,command.text,now+ClientSubmissionWindow.COMMAND_MILLISECONDS,rich=MessageRichContent.fromCommand(command))
        enqueue(next)
        db.execSQL("INSERT INTO text_send_replacements(original,replacement) VALUES (?,?)",arrayOf(operation,next.clientMessageId))
        return next.clientMessageId
    }
    fun abandonText(room: RoomId,viewer: UserId,operation: String) {
        requireUnsentText(room,viewer,operation)
        check(!db.rawQuery("SELECT 1 FROM text_send_replacements WHERE original=?",arrayOf(operation)).use {it.moveToFirst()}) {"此消息已创建新的发送记录"}
        db.execSQL("INSERT OR IGNORE INTO abandoned_text_sends(operation) VALUES (?)",arrayOf(operation))
    }
    fun tail(room: RoomId,viewer: UserId,limit: Int=40): PersistentList<Message> = read(room,viewer,limit,false).asReversed().toPersistentList()
    fun preview(room: RoomId): Message? = read(room,actor,1,true).firstOrNull()
    private fun read(room: RoomId,viewer: UserId,limit: Int,byTime: Boolean): List<Message> {
        require(limit in 1..100)
        if(viewer!=actor || revoked(room.value)) return emptyList()
        val order=if(byTime) "o.echo_created DESC,o.rowid DESC" else "o.rowid DESC"
        return db.rawQuery("""
            SELECT o.command,o.receipt,o.echo_message,o.send_work,o.echo_created FROM outbox o WHERE o.room=?
              AND NOT EXISTS(SELECT 1 FROM text_send_replacements r WHERE r.original=o.id)
              AND NOT EXISTS(SELECT 1 FROM abandoned_text_sends a WHERE a.operation=o.id)
              AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.id=o.echo_message AND m.room=o.room)
              AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=o.echo_message AND t.room=o.room)
            ORDER BY $order LIMIT ?
        """.trimIndent(),arrayOf(room.value,limit.toString())).use {rows->buildList {while(rows.moveToNext()) {
            val command=MessageSendOperation.parseFrom(rows.getBlob(0));val receipt=if(rows.isNull(1)) null else MessageSendOperationReceipt.parseFrom(rows.getBlob(1))
            require(command.roomId==room.value && command.senderUserId==actor.value && rows.getString(2)==echoId(command,receipt))
            add(Message(MessageId(rows.getString(2)),room,actor,command.text.ifEmpty {if(command.mediaIdsCount>0) "[附件]" else ""},rows.getLong(4).also { require(it >= 0) },
                when {receipt==null && !rows.isNull(3) && Json.decodeFromString<SendRecovery>(rows.getString(3)).status==SendRecoveryStatus.ExpiredUnsubmitted->Delivery.Failed;receipt==null->Delivery.Pending;receipt.hasAccepted()->Delivery.Accepted;else->Delivery.Failed},revision=0,
                media=MessageMedia(command.mediaIdsList.toPersistentList()),rich=MessageRichContent.fromCommand(command)))
        }}}
    }
    /** Read only the selected page. Completed entries never fall back to frozen original bodies. */
    fun history(room: RoomId,viewer: UserId,selection: SendHistorySelection,limit: Int): SendHistoryPage {
        require(limit in 1..100)
        if(viewer!=actor || revoked(room.value)) return SendHistoryPage()
        val cursor=when(selection) {SendHistorySelection.Latest->null;is SendHistorySelection.Before->selection.cursor;is SendHistorySelection.After->selection.cursor}
        require(cursor==null || (cursor.scope==historyScope && cursor.room==room && cursor.row>0)) {"Send continuation belongs to another store or room"}
        val ascending=selection is SendHistorySelection.After
        val order=if(ascending) "ASC" else "DESC"
        val predicate=if(cursor==null) "" else " AND o.rowid ${if(ascending) ">" else "<"} ?"
        val args=listOf(room.value)+(cursor?.let {listOf(it.row.toString())} ?: emptyList())+limit.toString()
        val selected=db.rawQuery("""
            SELECT o.rowid,o.id,o.command,o.receipt,o.echo_created,o.echo_message,m.text,m.revision,m.withdrawn,
                EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=o.echo_message AND t.room=o.room),o.send_work,
                (SELECT replacement FROM text_send_replacements r WHERE r.original=o.id),
                EXISTS(SELECT 1 FROM send_intents i WHERE i.operation=o.id),
                EXISTS(SELECT 1 FROM abandoned_text_sends a WHERE a.operation=o.id)
            FROM outbox o LEFT JOIN messages m ON m.id=o.echo_message AND m.room=o.room
            WHERE o.room=? $predicate ORDER BY o.rowid $order LIMIT ?
        """.trimIndent(),args.toTypedArray()).use {rows->buildList {while(rows.moveToNext()) {
            val receipt=if(rows.isNull(3)) null else MessageSendOperationReceipt.parseFrom(rows.getBlob(3))
            val delivery=when {receipt==null->Delivery.Pending;receipt.hasAccepted()->Delivery.Accepted;else->Delivery.Failed}
            val removed=rows.getInt(8)!=0 || rows.getInt(9)!=0
            val readable=!rows.isNull(6) && rows.getLong(7)>0 && !removed
            val text=when {
                removed->"消息已撤回或移除"
                readable->rows.getString(6)
                delivery==Delivery.Accepted || !rows.isNull(6)->"消息正文暂不可用"
                else->{
                    val command=MessageSendOperation.parseFrom(rows.getBlob(2))
                    require(command.clientMessageId==rows.getString(1) && command.roomId==room.value && command.senderUserId==actor.value)
                    command.text.ifEmpty {if(command.mediaIdsCount>0) "[附件]" else ""}
                }
            }
            val recovery=if(rows.isNull(10)) SendRecovery.Legacy else Json.decodeFromString<SendRecovery>(rows.getString(10))
            val status=when {
                receipt?.hasAccepted()==true->if(readable || removed) SendRecordStatus.Accepted else SendRecordStatus.AcceptedAwaitingProjection
                receipt?.hasRejected()==true->when(receipt.rejected.reasonValue) {1->SendRecordStatus.ExpiredUnsubmitted;6->SendRecordStatus.Closed;else->SendRecordStatus.Rejected}
                recovery.status==SendRecoveryStatus.ExpiredUnsubmitted->SendRecordStatus.ExpiredUnsubmitted
                recovery.status==SendRecoveryStatus.NeedsAttention->SendRecordStatus.NeedsAttention
                recovery.status==SendRecoveryStatus.WaitingForNetwork->SendRecordStatus.WaitingForNetwork
                recovery.status==SendRecoveryStatus.WaitingForAuthentication->SendRecordStatus.WaitingForAuthentication
                recovery.submitted->SendRecordStatus.Confirming
                else->SendRecordStatus.Pending
            }
            val replacement=if(rows.isNull(11)) null else rows.getString(11)
            val abandoned=rows.getInt(13)!=0
            val canReplace=if(!abandoned && replacement==null && rows.getInt(12)==0 && !readable && !removed && status in setOf(SendRecordStatus.ExpiredUnsubmitted,SendRecordStatus.Closed,SendRecordStatus.Rejected)) {
                val command=MessageSendOperation.parseFrom(rows.getBlob(2))
                command.mediaIdsCount==0 && command.text.isNotBlank() && provenUnsent(command,receipt,recovery)
            } else false
            add(rows.getLong(0) to SendHistoryItem(rows.getString(1),text,rows.getLong(4),if(recovery.status==SendRecoveryStatus.ExpiredUnsubmitted && receipt==null) Delivery.Failed else delivery,if(readable) MessageId(rows.getString(5)) else null,status,canReplace,replacement,abandoned))
        }}}
        val ordered=if(ascending) selected.reversed() else selected
        fun boundary(row: Long,comparison: String): SendHistoryCursor? = db.rawQuery(
            "SELECT 1 FROM outbox WHERE room=? AND rowid $comparison ? LIMIT 1",arrayOf(room.value,row.toString())
        ).use {if(it.moveToFirst()) SendHistoryCursor(historyScope,room,row) else null}
        return SendHistoryPage(ordered.map {it.second}.toPersistentList(),ordered.firstOrNull()?.let {boundary(it.first,">")},ordered.lastOrNull()?.let {boundary(it.first,"<")})
    }
    private fun created(command: MessageSendOperation)=command.firstSubmissionDeadlineMs-600_000
    private fun echoId(command: MessageSendOperation,receipt: MessageSendOperationReceipt?)=if(receipt?.hasAccepted()==true) receipt.accepted.messageId else command.clientMessageId
}
