package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.*

/** All writes run in the parent store's transaction, including migration and personal cursor advancement. */
internal class SqliteAccountRoomHeads(private val db: SQLiteDatabase) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS account_room_heads (room TEXT PRIMARY KEY, sequence INTEGER NOT NULL CHECK(sequence>0), membership INTEGER NOT NULL CHECK(membership>=0), blocked INTEGER NOT NULL DEFAULT 0 CHECK(blocked IN (0,1)))")
        db.execSQL("CREATE TABLE IF NOT EXISTS projection_migrations (name TEXT PRIMARY KEY)")
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='account_room_heads_v1'",null).use {!it.moveToFirst()}) {
            db.rawQuery("SELECT payload FROM records WHERE kind='room_head'",null).use { rows -> while(rows.moveToNext()) {
                project(AccountRoomHead.decode(Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject))
            } }
            db.execSQL("DELETE FROM records WHERE kind='room_head'")
            db.execSQL("INSERT INTO projection_migrations VALUES ('account_room_heads_v1')")
        }
    } }
    fun project(head: AccountRoomHead) {
        val old=db.rawQuery("SELECT sequence,membership FROM account_room_heads WHERE room=?",arrayOf(head.room.value)).use {
            if(it.moveToFirst()) AccountRoomHead(head.room,it.getLong(0),it.getLong(1)) else null
        }
        val merged=old?.merging(head) ?: head
        if(merged == old) return
        if(old == null) db.execSQL("INSERT INTO account_room_heads(room,sequence,membership) VALUES (?,?,?)",
            arrayOf<Any>(merged.room.value,merged.sequence,merged.membershipRevision))
        else db.execSQL("UPDATE account_room_heads SET sequence=?,membership=? WHERE room=?",
            arrayOf<Any>(merged.sequence,merged.membershipRevision,merged.room.value))
    }
    fun deny(room: String) {db.execSQL("UPDATE account_room_heads SET blocked=1 WHERE room=?",arrayOf(room))}
    fun authorize(room: String) {db.execSQL("UPDATE account_room_heads SET blocked=0 WHERE room=?",arrayOf(room))}
    fun pending(after: RoomId?, limit: Int): PersistentList<AccountRoomHead> {
        require(limit in 1..64)
        fun read(cursor: RoomId?) = db.rawQuery("""
            SELECT h.room,h.sequence,h.membership FROM account_room_heads h
            LEFT JOIN room_cursors c ON c.room=h.room LEFT JOIN memberships m ON m.room=h.room
            WHERE h.blocked=0 AND COALESCE(m.member,1)=1 AND h.sequence>COALESCE(c.sequence,0)
            ${if(cursor != null) "AND h.room>?" else ""} ORDER BY h.room LIMIT ?
        """.trimIndent(),if(cursor == null) arrayOf(limit.toString()) else arrayOf(cursor.value,limit.toString())).use { rows ->
            buildList {while(rows.moveToNext()) add(AccountRoomHead(RoomId(rows.getString(0)),rows.getLong(1),rows.getLong(2)))}.toPersistentList()
        }
        val page=read(after)
        return if(page.isEmpty() && after != null) read(null) else page
    }
}
