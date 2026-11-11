package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import java.util.UUID

/** Invoked within the store transaction. Only canonical invalidation facts survive a room read. */
internal class SqliteGroupAvatars(private val db: SQLiteDatabase) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS group_avatar_effects (source TEXT NOT NULL,room TEXT NOT NULL,revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),sequence INTEGER NOT NULL CHECK(typeof(sequence)='integer' AND sequence>0),time INTEGER NOT NULL CHECK(typeof(time)='integer' AND time>=0),digest TEXT NOT NULL,PRIMARY KEY(source,room),UNIQUE(room,revision),UNIQUE(room,sequence))")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_avatar_epochs (room TEXT PRIMARY KEY,generation TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS group_avatar_epoch (id INTEGER PRIMARY KEY CHECK(id=1),generation TEXT NOT NULL)")
        db.execSQL("INSERT OR IGNORE INTO group_avatar_epoch VALUES (1,?)",arrayOf(UUID.randomUUID().toString()))
    } }
    fun generation()=db.rawQuery("SELECT generation FROM group_avatar_epoch WHERE id=1",null).use { check(it.moveToFirst());it.getString(0) }
    fun invalidate(room: String) {
        db.execSQL("INSERT OR REPLACE INTO group_avatar_epochs VALUES (?,?)",arrayOf(room,UUID.randomUUID().toString()))
        changed()
    }
    private fun changed() { db.execSQL("UPDATE group_avatar_epoch SET generation=? WHERE id=1",arrayOf(UUID.randomUUID().toString())) }
    fun clearEpochs() { db.execSQL("DELETE FROM group_avatar_epochs");changed() }
    fun fence(room: RoomId): GroupAvatarFence {
        val revision=db.rawQuery("SELECT MAX(revision) FROM group_avatar_effects WHERE room=?",arrayOf(room.value)).use { it.moveToFirst();if(it.isNull(0)) 0L else it.getLong(0) }
        val epoch=db.rawQuery("SELECT generation FROM group_avatar_epochs WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) it.getString(0) else "" }
        val membership=db.rawQuery("SELECT revision,member FROM memberships WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) it.getLong(0) to (it.getInt(1)==1) else 0L to false }
        return GroupAvatarFence(epoch,revision,membership.first,membership.second)
    }
    fun project(effect: GroupAvatarEffect) {
        var duplicate=false
        db.rawQuery("SELECT source,revision,sequence,time,digest FROM group_avatar_effects WHERE room=? AND (source=? OR revision=? OR sequence=?)",
            arrayOf(effect.room.value,effect.source,effect.revision.toString(),effect.sequence.toString())).use { rows ->
            while(rows.moveToNext()) {
                require(rows.getString(0)==effect.source && rows.getLong(1)==effect.revision && rows.getLong(2)==effect.sequence && rows.getLong(3)==effect.updatedAt && rows.getString(4)==effect.digest)
                duplicate=true
            }
        }
        if(duplicate) return
        // Validate both neighbours, so out-of-order migration cannot hide a contradictory middle revision.
        db.rawQuery("SELECT 1 FROM group_avatar_effects WHERE room=? AND ((revision<? AND sequence>=?) OR (revision>? AND sequence<=?)) LIMIT 1",
            arrayOf(effect.room.value,effect.revision.toString(),effect.sequence.toString(),effect.revision.toString(),effect.sequence.toString())).use { require(!it.moveToFirst()) }
        val previous=fence(effect.room).revision
        db.execSQL("INSERT INTO group_avatar_effects VALUES (?,?,?,?,?,?)",arrayOf<Any>(effect.source,effect.room.value,effect.revision,effect.sequence,effect.updatedAt,effect.digest))
        if(effect.revision>previous) invalidate(effect.room.value)
    }
    fun purge(room: String) {
        db.execSQL("DELETE FROM group_avatar_effects WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM group_avatar_epochs WHERE room=?",arrayOf(room));changed()
    }
    fun finishSnapshot() {
        for(table in listOf("group_avatar_effects","group_avatar_epochs"))
            db.execSQL("DELETE FROM $table WHERE room NOT IN (SELECT m.room FROM memberships m JOIN metadata_grants p ON p.room=m.room AND p.revision=m.revision WHERE m.member=1)")
    }
}
