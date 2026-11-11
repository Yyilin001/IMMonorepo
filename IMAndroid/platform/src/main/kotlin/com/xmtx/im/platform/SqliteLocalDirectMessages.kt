package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*

/** All calls run in the account store transaction. No room IDs are invented for pending work. */
internal class SqliteLocalDirectMessages(private val db: SQLiteDatabase, private val actor: UserId) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS local_direct_messages (id TEXT PRIMARY KEY,operation TEXT NOT NULL REFERENCES direct_operations(id),text TEXT NOT NULL CHECK(length(text)>0 AND length(CAST(text AS BLOB))<=65536),created INTEGER NOT NULL CHECK(created>=0))")
        db.execSQL("CREATE INDEX IF NOT EXISTS local_direct_messages_work ON local_direct_messages(operation,created,id)")
    } }
    fun work(operation: String): DirectRoomWork = db.rawQuery("SELECT work FROM direct_operations WHERE id=?", arrayOf(operation)).use {
        check(it.moveToFirst()) { "本地聊天请求已不可用" }
        Json.decodeFromString<DirectRoomWork>(it.getString(0)).also { work -> require(work.command.actor == actor && work.command.operation == operation) }
    }
    fun all(operation: String? = null): PersistentList<LocalDirectMessage> {
        if (!db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_direct_messages'", null).use { it.moveToFirst() }) return persistentListOf()
        return db.rawQuery("SELECT id,operation,text,created FROM local_direct_messages" + (if (operation == null) "" else " WHERE operation=?") + " ORDER BY created,rowid",
            operation?.let { arrayOf(it) }).use { rows ->
            buildList { while (rows.moveToNext()) add(LocalDirectMessage(rows.getString(0), rows.getString(1), rows.getString(2), rows.getLong(3))) }.toPersistentList()
        }
    }
    private fun readMessage(id: String): LocalDirectMessage? = db.rawQuery("SELECT id,operation,text,created FROM local_direct_messages WHERE id=?", arrayOf(id)).use {
        if (it.moveToFirst()) LocalDirectMessage(it.getString(0), it.getString(1), it.getString(2), it.getLong(3)) else null
    }
    fun save(message: LocalDirectMessage) {
        work(message.operation)
        readMessage(message.id)?.let { require(it == message); return }
        // A handoff may have committed before the caller observed success. Never recreate that row.
        db.rawQuery("SELECT payload FROM send_intents WHERE id=?", arrayOf(message.id)).use {
            if (it.moveToFirst()) {
                val sent = Json.decodeFromString<SendIntent>(it.getString(0))
                val room = openedRoom(work(message.operation))
                require(room != null); validateSend(sent, message, room); return
            }
        }
        check(db.compileStatement("SELECT COUNT(*) FROM local_direct_messages").use { it.simpleQueryForLong() } < 500) { "本地待发送消息已满，请先处理现有消息" }
        db.execSQL("INSERT INTO local_direct_messages VALUES (?,?,?,?)", arrayOf<Any>(message.id, message.operation, message.text, message.createdAt))
        check(readMessage(message.id) == message)
    }
    fun reassign(target: UserId, operation: String) {
        val matches = db.rawQuery("SELECT id,work FROM direct_operations WHERE id<>?", arrayOf(operation)).use { rows ->
            buildList { while (rows.moveToNext()) {
                val old = Json.decodeFromString<DirectRoomWork>(rows.getString(1)); require(old.command.actor == actor)
                if (old.command.target == target) add(rows.getString(0))
            } }
        }
        for (old in matches) db.execSQL("UPDATE local_direct_messages SET operation=? WHERE operation=?", arrayOf(operation, old))
    }
    fun openedRoom(work: DirectRoomWork): RoomId? {
        if (work.status != DirectWorkStatus.Opened) return null
        val receipt = DirectRoomClient.decodeReceipt(work.command, Json.parseToJsonElement(requireNotNull(work.receipt)).jsonObject)
        require(receipt.room != null && receipt.room == work.room)
        return receipt.room
    }
    private fun validateSend(sent: SendIntent, message: LocalDirectMessage, room: RoomId) {
        require(sent.actor == actor && sent.room == room && sent.id == message.id && sent.operation == message.id &&
            sent.text == message.text && sent.createdAt == message.createdAt && sent.attachments.isEmpty() && sent.serverImports.isEmpty() && sent.rich == MessageRichContent.Empty)
    }
    fun prepareNext(now: Long, sends: SqliteSendIntents): Boolean {
        val ready = all().firstNotNullOfOrNull { message -> openedRoom(work(message.operation))?.let { message to it } } ?: return false
        val (message, room) = ready
        val existing = sends.statuses().firstOrNull { it.intent.id == message.id }?.intent
        if (existing != null) validateSend(existing, message, room)
        else {
            val intent = SendIntent(message.id, actor, room, message.id, message.text, persistentListOf(), message.createdAt,
                Math.addExact(now, 86_400_000), preparationStartedAt = now)
            sends.enqueue(intent, now)
            check(sends.statuses().firstOrNull { it.intent.id == message.id }?.intent == intent)
        }
        db.execSQL("DELETE FROM local_direct_messages WHERE id=?", arrayOf(message.id))
        check(db.compileStatement("SELECT changes()").use { it.simpleQueryForLong() } == 1L && readMessage(message.id) == null)
        return true
    }
}
