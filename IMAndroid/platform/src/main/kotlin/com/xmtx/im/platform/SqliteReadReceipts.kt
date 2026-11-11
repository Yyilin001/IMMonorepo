package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import java.util.UUID

/** Invoked only under the parent store's mutex; mutations share its transaction. */
internal class SqliteReadReceipts(private val db: SQLiteDatabase,private val actor: UserId) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS read_intents (room TEXT PRIMARY KEY,sequence INTEGER NOT NULL CHECK(typeof(sequence)='integer' AND sequence>0))")
        db.execSQL("CREATE TABLE IF NOT EXISTS read_operations (id TEXT PRIMARY KEY,room TEXT NOT NULL,work TEXT NOT NULL)")
        db.execSQL("CREATE INDEX IF NOT EXISTS read_operations_room ON read_operations(room)")
        db.execSQL("CREATE TABLE IF NOT EXISTS read_confirmed (room TEXT PRIMARY KEY,watermark TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS own_read_projections (room TEXT PRIMARY KEY,watermark TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS direct_read_projections (room TEXT PRIMARY KEY,value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS read_room_state (room TEXT PRIMARY KEY,head INTEGER NOT NULL,own INTEGER NOT NULL,read INTEGER NOT NULL)")
    } }
    fun works(): PersistentList<ReadWork> = db.rawQuery("SELECT work FROM read_operations ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<ReadWork>(rows.getString(0)).also { require(it.command.actor == actor) }) }.toPersistentList()
    }
    private fun saved(id: String) = db.rawQuery("SELECT work FROM read_operations WHERE id=?",arrayOf(id)).use { if(it.moveToFirst()) Json.decodeFromString<ReadWork>(it.getString(0)) else null }
    private fun put(work: ReadWork) {
        require(work.command.actor == actor)
        val value = Json.encodeToString(work)
        db.execSQL("UPDATE read_operations SET work=? WHERE id=? AND room=?",arrayOf(value,work.command.operation,work.command.room.value))
        if(db.compileStatement("SELECT changes()").use { it.simpleQueryForLong() } == 0L)
            db.execSQL("INSERT INTO read_operations VALUES (?,?,?)",arrayOf(work.command.operation,work.command.room.value,value))
    }
    private fun high(room: RoomId): Long = watermarks(persistentListOf(room))[room] ?: 0

    /** Four indexed queries per bounded page, independent of the number of requested rooms. */
    fun watermarks(rooms: PersistentList<RoomId>): PersistentMap<RoomId,Long> {
        require(rooms.size <= 128)
        if(rooms.isEmpty()) return persistentMapOf()
        val requested=rooms.distinct();val arguments=requested.map {it.value}.toTypedArray()
        val placeholders=arguments.joinToString(",") {"?"}
        val result=mutableMapOf<RoomId,Long>()
        fun accept(room:RoomId,sequence:Long) {
            require(room in requested && sequence > 0)
            result[room]=maxOf(result[room] ?: 0,sequence)
        }
        for(table in listOf("read_confirmed","own_read_projections")) {
            db.rawQuery("SELECT room,watermark FROM $table WHERE room IN ($placeholders)",arguments).use {rows->
                while(rows.moveToNext()) {
                    val room=RoomId(rows.getString(0));val value=Json.decodeFromString<ReadWatermark>(rows.getString(1))
                    require(value.room==room && value.user==actor);accept(room,value.sequence)
                }
            }
        }
        db.rawQuery("SELECT room,sequence FROM read_intents WHERE room IN ($placeholders)",arguments).use {rows->
            while(rows.moveToNext()) accept(RoomId(rows.getString(0)),rows.positive(1))
        }
        db.rawQuery("SELECT room,id,work FROM read_operations WHERE room IN ($placeholders)",arguments).use {rows->
            while(rows.moveToNext()) {
                val room=RoomId(rows.getString(0));val work=Json.decodeFromString<ReadWork>(rows.getString(2))
                require(work.command.actor==actor && work.command.room==room && work.command.operation==rows.getString(1))
                // All current ReadStatus cases retain local reading evidence; Archived only stops recovery.
                accept(room,work.command.sequence)
            }
        }
        return result.toPersistentMap()
    }

    fun unreadCounts(rooms:List<RoomId>): PersistentMap<RoomId,Int> {
        val result=mutableMapOf<RoomId,Int>()
        for(page in rooms.distinct().chunked(128)) {
            val watermarks=watermarks(page.toPersistentList())
            val arguments=page.map {it.value}.toTypedArray();val placeholders=arguments.joinToString(",") {"?"}
            db.rawQuery("SELECT c.room,c.unread,s.head FROM room_cursors c LEFT JOIN read_room_state s ON s.room=c.room WHERE c.room IN ($placeholders)",arguments).use {rows->
                while(rows.moveToNext()) {
                    val room=RoomId(rows.getString(0));val serverUnread=rows.nonnegative(1)
                    val unread=if(rows.isNull(2)) serverUnread else ConversationUnread.displayedUnread(serverUnread,rows.nonnegative(2),watermarks[room])
                    result[room]=unread.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                }
            }
        }
        return result.toPersistentMap()
    }
    private fun confirmed(room: RoomId): Long = listOf("read_confirmed","own_read_projections").maxOf { table ->
        db.rawQuery("SELECT watermark FROM $table WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) Json.decodeFromString<ReadWatermark>(it.getString(0)).sequence else 0 }
    }
    fun enqueue(room: RoomId,sequence: Long): Boolean {
        require(sequence > 0);ReadCommand(actor,room,UUID.randomUUID().toString().uppercase(),sequence)
        if(sequence <= high(room)) return false
        db.execSQL("INSERT OR REPLACE INTO read_intents VALUES (?,?)",arrayOf<Any>(room.value,sequence));return true
    }
    fun prepare(limit: Int) {
        require(limit in 1..100)
        val active = works().filter { it.active }.map { it.command.room }.toSet()
        val pending = db.rawQuery("SELECT room,sequence FROM read_intents ORDER BY room",null).use { rows -> buildList {
            while(rows.moveToNext() && size < limit) { val room = RoomId(rows.getString(0));if(room !in active) add(room to rows.positive(1)) }
        } }
        for((room,sequence) in pending) {
            if(sequence > confirmed(room)) put(ReadWork(ReadCommand(actor,room,UUID.randomUUID().toString().uppercase(),sequence)))
            db.execSQL("DELETE FROM read_intents WHERE room=?",arrayOf(room.value))
        }
    }
    fun update(expected: ReadWork,updated: ReadWork) {
        check(saved(expected.command.operation) == expected);require(expected.command == updated.command && expected.active)
        require(!expected.submissionStarted || updated.submissionStarted)
        require(expected.control == updated.control && updated.status != ReadStatus.Archived)
        if(updated.status == ReadStatus.Confirmed) { require(updated.submissionStarted);saveWatermark(requireNotNull(updated.watermark),"read_confirmed") }
        put(updated)
    }
    fun archive(operation: String,now: Long) {
        require(now >= 0);val work = requireNotNull(saved(operation))
        require(work.status == ReadStatus.NeedsAttention && work.submissionStarted && (work.reason?.startsWith("currentUnavailable:") == true || work.control && work.reason == "controlCapacityRequired"))
        val archives = works().filter { it.status == ReadStatus.Archived }
        val bytes = work.command.payload().toString().toByteArray().size
        check(archives.size < 256 && bytes <= 4096 && archives.sumOf { it.command.payload().toString().toByteArray().size }+bytes <= 1048576)
        put(work.copy(status = ReadStatus.Archived,archivedAt = now))
    }
    fun restore(operation: String,now: Long) {
        require(now >= 0);val work = requireNotNull(saved(operation));require(work.status == ReadStatus.Archived)
        put(work.copy(status = ReadStatus.Pending,archivedAt = null,control = true,reconcile = true,attempts = 0,roundStarted = null,reason = null,nextAttempt = maxOf(now,work.nextAttempt)))
    }
    fun admit(expected: ReadWork,updated: ReadWork,ordinaryAllowed: Boolean) {
        check(saved(expected.command.operation) == expected);require(expected.control && expected.active && expected.command == updated.command && !updated.control && !updated.reconcile)
        if(ordinaryAllowed && works().none { it.active && !it.control && it.command.room == expected.command.room }) put(updated)
        else put(expected.copy(status = ReadStatus.NeedsAttention,reason = "controlCapacityRequired",nextAttempt = updated.nextAttempt))
    }
    fun saveWatermark(value: ReadWatermark,table: String = "own_read_projections") {
        require(value.user == actor && table in setOf("own_read_projections","read_confirmed"))
        val old = db.rawQuery("SELECT watermark FROM $table WHERE room=?",arrayOf(value.room.value)).use { if(it.moveToFirst()) Json.decodeFromString<ReadWatermark>(it.getString(0)) else null }
        if(old != null && (old.sequence > value.sequence || old.sequence == value.sequence && table == "read_confirmed")) return
        db.execSQL("INSERT OR REPLACE INTO $table VALUES (?,?)",arrayOf(value.room.value,Json.encodeToString(value)))
    }
    fun project(kind: String,value: JsonObject) {
        when(kind) {
            "own_read_watermark" -> saveWatermark(ReadWatermark(RoomId(value.getValue("room_id").jsonPrimitive.content),actor,value.number("read_through_room_sequence"),value.number("recorded_at_ms")))
            "direct_read_receipt" -> {
                val next = DirectReadProjection.decode(value);require(next.reader != actor)
                val old = db.rawQuery("SELECT value FROM direct_read_projections WHERE room=?",arrayOf(next.room.value)).use { if(it.moveToFirst()) Json.decodeFromString<DirectReadProjection>(it.getString(0)) else null }
                val merged = next.replacing(old)
                db.execSQL("INSERT OR REPLACE INTO direct_read_projections VALUES (?,?)",arrayOf(next.room.value,Json.encodeToString(merged)))
            }
        }
    }
    fun state(room: RoomId,head: Long,own: Long,read: Long) {
        require(head >= 0 && own in 0..head && read in 0..head)
        db.execSQL("INSERT OR REPLACE INTO read_room_state VALUES (?,?,?,?)",arrayOf<Any>(room.value,head,own,read))
    }
    fun latest(room: RoomId): Long? = db.rawQuery("SELECT c.sequence,s.head FROM room_cursors c LEFT JOIN read_room_state s ON s.room=c.room JOIN memberships m ON m.room=c.room AND m.member=1 WHERE c.room=?",arrayOf(room.value)).use {
        if(!it.moveToFirst()) null else (if(it.isNull(1)) it.getLong(0) else minOf(it.getLong(0),it.getLong(1))).takeIf { value -> value > 0 }
    }
    fun checkpoints(): PersistentList<RoomReadCheckpoint> = db.rawQuery("SELECT c.room,c.sequence,s.head FROM room_cursors c LEFT JOIN read_room_state s ON s.room=c.room JOIN memberships m ON m.room=c.room AND m.member=1",null).use { rows ->
        buildList { while(rows.moveToNext()) add(RoomReadCheckpoint(RoomId(rows.getString(0)),rows.getLong(1),if(rows.isNull(2)) null else rows.getLong(2))) }.toPersistentList()
    }
    fun visible(): PersistentList<DirectReadProjection> = db.rawQuery("SELECT p.value FROM direct_read_projections p JOIN room_kinds k ON k.room=p.room AND k.kind='Direct' WHERE p.room NOT IN (SELECT room FROM memberships WHERE member=0)",null).use { rows ->
        buildList { while(rows.moveToNext()) { val value = Json.decodeFromString<DirectReadProjection>(rows.getString(0));if(value.visible && value.sequence > 0) add(value) } }.toPersistentList()
    }
}
private fun Cursor.positive(index: Int): Long { require(getType(index) == Cursor.FIELD_TYPE_INTEGER && getLong(index) > 0);return getLong(index) }
private fun JsonObject.number(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()

private fun Cursor.nonnegative(index:Int):Long { require(getType(index)==Cursor.FIELD_TYPE_INTEGER && getLong(index)>=0);return getLong(index) }
