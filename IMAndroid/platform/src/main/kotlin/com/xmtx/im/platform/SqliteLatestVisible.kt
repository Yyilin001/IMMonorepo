package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

internal class SqliteLatestVisible(private val db: SQLiteDatabase) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS latest_visible (room TEXT PRIMARY KEY,generation INTEGER NOT NULL,owner INTEGER NOT NULL,membership INTEGER NOT NULL,head INTEGER NOT NULL,message TEXT,revision INTEGER,payload TEXT NOT NULL)")
        db.execSQL("CREATE INDEX IF NOT EXISTS latest_visible_message ON latest_visible(message)")
        db.execSQL("CREATE TABLE IF NOT EXISTS room_observed_heads (room TEXT PRIMARY KEY,head INTEGER NOT NULL CHECK(head>=0))")
        if(db.rawQuery("SELECT 1 FROM projection_migrations WHERE name='latest_visible_v1'",null).use {!it.moveToFirst()}) {
            db.execSQL("INSERT OR IGNORE INTO directory_work(room,revision) SELECT room,hex(randomblob(16)) FROM room_cursors WHERE room NOT IN(SELECT room FROM memberships WHERE member=0)")
            db.execSQL("UPDATE directory_work SET summary=1,revision=hex(randomblob(16)) WHERE room IN(SELECT room FROM room_cursors) AND room NOT IN(SELECT room FROM memberships WHERE member=0)")
            db.execSQL("INSERT INTO projection_migrations VALUES ('latest_visible_v1')")
        }
        // SQLite triggers avoid optional UPSERT or unixepoch() dependencies. Requeue is atomic with the invalidating write.
        db.execSQL("DROP TRIGGER IF EXISTS latest_visible_requeue")
        db.execSQL("""CREATE TRIGGER latest_visible_requeue AFTER DELETE ON latest_visible
            WHEN EXISTS(SELECT 1 FROM cursor WHERE generation=OLD.generation)
              AND EXISTS(SELECT 1 FROM room_cursors WHERE room=OLD.room)
              AND NOT EXISTS(SELECT 1 FROM memberships WHERE room=OLD.room AND member=0)
            BEGIN
              INSERT OR IGNORE INTO directory_work(room,revision,enqueued) VALUES (OLD.room,hex(randomblob(16)),(SELECT COALESCE(MAX(enqueued),0)+1 FROM directory_work));
              UPDATE directory_work SET revision=hex(randomblob(16)),summary=1,priority=MAX(priority,1),target_head=MAX(target_head,OLD.head) WHERE room=OLD.room;
            END""")
        for(operation in listOf("INSERT","UPDATE")) {
            trigger("state_${operation.lowercase()}",operation,"room_cursors", "room=NEW.room AND (owner<>NEW.owner OR membership<>NEW.membership OR head<NEW.sequence)")
            trigger("member_${operation.lowercase()}",operation,"memberships", "room=NEW.room AND (membership<NEW.revision OR (membership=NEW.revision AND NEW.member=0))")
            trigger("message_${operation.lowercase()}",operation,"messages", "room=NEW.room AND (head<NEW.sequence OR (message=NEW.id AND (revision<NEW.revision OR NEW.withdrawn=1)))")
            trigger("tombstone_${operation.lowercase()}",operation,"message_tombstones", "message=NEW.id")
        }
        db.execSQL("""CREATE TRIGGER IF NOT EXISTS latest_visible_state_delete AFTER DELETE ON room_cursors BEGIN
            DELETE FROM latest_visible WHERE room=OLD.room; DELETE FROM room_observed_heads WHERE room=OLD.room; END""")
        trigger("generation","UPDATE","cursor","generation<>NEW.generation")
    } }
    private fun trigger(name: String,event: String,table: String,condition: String) {
        db.execSQL("CREATE TRIGGER IF NOT EXISTS latest_visible_$name AFTER $event ON $table BEGIN DELETE FROM latest_visible WHERE $condition; END")
    }
    fun state(room: RoomId,state: com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState) {
        db.execSQL("INSERT OR REPLACE INTO room_observed_heads VALUES (?,?)",arrayOf<Any>(room.value,state.head))
        db.execSQL("DELETE FROM latest_visible WHERE room=? AND (owner<>? OR membership<>? OR head<?)",arrayOf<Any>(room.value,state.ownerEpoch,state.viewerMembershipRevision,state.head))
    }
    fun current(value: LatestVisibleSnapshot): Boolean {
        value.validate();val room=value.room.value
        db.rawQuery("SELECT c.sequence,c.owner,c.membership,COALESCE(h.head,0) FROM room_cursors c LEFT JOIN room_observed_heads h ON h.room=c.room WHERE c.room=?",arrayOf(room)).use {
            if(!it.moveToFirst()) return false
            if(it.getLong(0)>value.head || it.getLong(1)!=value.owner || it.getLong(2)!=value.membership || it.getLong(3)>value.head) return false
        }
        if(db.rawQuery("SELECT 1 FROM memberships WHERE room=? AND (revision>? OR member=0)",arrayOf(room,value.membership.toString())).use {it.moveToFirst()}) return false
        if(db.rawQuery("SELECT 1 FROM messages WHERE room=? AND sequence>? LIMIT 1",arrayOf(room,value.head.toString())).use {it.moveToFirst()}) return false
        value.latest?.let {message ->
            if(db.rawQuery("SELECT 1 FROM message_tombstones WHERE id=?",arrayOf(message.id.value)).use {it.moveToFirst()}) return false
            if(db.rawQuery("SELECT room,revision,withdrawn FROM messages WHERE id=?",arrayOf(message.id.value)).use {
                it.moveToFirst() && (it.getString(0)!=room || it.getLong(1)>message.revision || it.getInt(2)!=0)
            }) return false
        }
        return true
    }
    fun commit(value: LatestVisibleSnapshot,generation: Long,work: RoomDirectoryWork): Boolean {
        if(value.room != work.room) throw ClientFailure.Protocol()
        if(!current(value)) return false
        val old=read(value.room,generation)
        if(old != null) {
            if(old.owner>value.owner || old.membership>value.membership || old.head>value.head) return false
            if(old.owner==value.owner && old.membership==value.membership && old.head==value.head && old!=value) return false
        }
        val values=arrayOf<Any?>(generation,value.owner,value.membership,value.head,value.latest?.id?.value,value.latest?.revision,Json.encodeToString(value),value.room.value)
        db.execSQL("INSERT OR IGNORE INTO latest_visible VALUES (?,?,?,?,?,?,?,?)",arrayOf<Any?>(value.room.value,generation,value.owner,value.membership,value.head,value.latest?.id?.value,value.latest?.revision,Json.encodeToString(value)))
        db.execSQL("UPDATE latest_visible SET generation=?,owner=?,membership=?,head=?,message=?,revision=?,payload=? WHERE room=?",values)
        db.execSQL("UPDATE directory_work SET summary=0,target_head=MAX(target_head,?) WHERE room=? AND revision=?",arrayOf<Any>(value.head,work.room.value,work.revision))
        return true
    }
    fun read(room: RoomId,generation: Long): LatestVisibleSnapshot? = db.rawQuery("SELECT payload FROM latest_visible WHERE room=? AND generation=?",arrayOf(room.value,generation.toString())).use {
        if(it.moveToFirst()) Json.decodeFromString<LatestVisibleSnapshot>(it.getString(0)).takeIf(::current) else null
    }
    fun all(generation: Long): Map<RoomId,LatestVisibleSnapshot> = db.rawQuery("SELECT payload FROM latest_visible WHERE generation=?",arrayOf(generation.toString())).use {rows ->
        buildMap {while(rows.moveToNext()) {val value=Json.decodeFromString<LatestVisibleSnapshot>(rows.getString(0));if(current(value)) put(value.room,value)}}
    }
}
