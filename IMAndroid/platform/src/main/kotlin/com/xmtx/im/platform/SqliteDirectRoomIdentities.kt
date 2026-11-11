package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.Json

/** Owning store mutex/transaction only. This table never enrolls a room for network or local reads. */
internal class SqliteDirectRoomIdentities(private val db: SQLiteDatabase, private val actor: UserId) {
    init { if (!db.isReadOnly) db.execSQL("CREATE TABLE IF NOT EXISTS local_direct_room_identities (room TEXT PRIMARY KEY,user TEXT NOT NULL,identity TEXT NOT NULL,created INTEGER NOT NULL CHECK(created>=0),updated INTEGER NOT NULL CHECK(updated>=0))") }
    fun validate(room: RoomId, peer: UserId, created: Long) {
        require(peer != actor && created >= 0)
        for (table in listOf("local_direct_room_identities", "direct_profile_bindings")) {
            db.rawQuery("SELECT user,created FROM $table WHERE room=?", arrayOf(room.value)).use {
                if (it.moveToFirst()) require(it.getString(0) == peer.value && it.getLong(1) == created)
            }
        }
    }
    fun save(value: DirectRoomIdentity) {
        validate(value.room, value.publicIdentity.user, value.roomCreatedAt)
        db.execSQL("INSERT INTO local_direct_room_identities VALUES (?,?,?,?,?) ON CONFLICT(room) DO UPDATE SET identity=excluded.identity,updated=excluded.updated WHERE excluded.updated>=updated",
            arrayOf(value.room.value, value.publicIdentity.user.value, Json.encodeToString(PublicIdentitySerializer, value.publicIdentity), value.roomCreatedAt, value.updatedAt))
    }
    fun all(): kotlinx.collections.immutable.PersistentList<DirectRoomIdentity> {
        if (!db.rawQuery("SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_direct_room_identities'", null).use { it.moveToFirst() }) return kotlinx.collections.immutable.persistentListOf()
        return db.rawQuery("SELECT room,user,identity,created,updated FROM local_direct_room_identities ORDER BY updated DESC,room", null).use { rows ->
        buildList { while (rows.moveToNext()) {
            val identity = Json.decodeFromString(PublicIdentitySerializer, rows.getString(2))
            require(identity.user.value == rows.getString(1) && identity.user != actor)
            add(DirectRoomIdentity(RoomId(rows.getString(0)), identity, rows.getLong(3), rows.getLong(4)))
        } }.toPersistentList()
    }
    }
    /** Called after live invalidation, or after the complete snapshot has been projected. */
    fun pruneSecurity(user: UserId? = null) {
        db.execSQL("""DELETE FROM local_direct_room_identities AS d WHERE ${if (user == null) "1" else "d.user=?"}
            AND EXISTS (SELECT 1 FROM presentation_floors f WHERE f.kind='security' AND f.room='' AND f.user=d.user
                AND NOT EXISTS (SELECT 1 FROM direct_profile_bindings p WHERE p.user=d.user AND p.revision>f.revision)
                AND NOT EXISTS (SELECT 1 FROM local_profile_displays p WHERE p.user=d.user AND p.value IS NOT NULL AND p.revision>f.revision))""",
            if (user == null) emptyArray<Any>() else arrayOf(user.value))
    }
}
