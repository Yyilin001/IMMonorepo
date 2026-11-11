package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentMap
import kotlinx.serialization.json.*
import java.util.UUID

/** Called only inside the owning store's mutex/transaction. No names or leases are persisted. */
internal class SqliteProfilePresentations(private val db: SQLiteDatabase, private val changed: () -> Unit = {}) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS presentation_epoch (id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL)")
        db.execSQL("INSERT OR IGNORE INTO presentation_epoch VALUES (1,?)",arrayOf(UUID.randomUUID().toString()))
        db.execSQL("CREATE TABLE IF NOT EXISTS presentation_floors (kind TEXT NOT NULL,room TEXT NOT NULL,user TEXT NOT NULL,revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),PRIMARY KEY(kind,room,user))")
        db.execSQL("CREATE TABLE IF NOT EXISTS nickname_effects (source TEXT NOT NULL,room TEXT NOT NULL,user TEXT NOT NULL,revision INTEGER NOT NULL,sequence INTEGER NOT NULL,time INTEGER NOT NULL,PRIMARY KEY(source,room),UNIQUE(room,user,revision),UNIQUE(room,sequence))")
        db.execSQL("CREATE TABLE IF NOT EXISTS direct_account_kinds(room TEXT PRIMARY KEY,user TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),kind TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS direct_profile_bindings (room TEXT PRIMARY KEY,user TEXT NOT NULL,revision INTEGER NOT NULL,created INTEGER NOT NULL,digest TEXT NOT NULL)")
    } }
    fun direct(value: JsonObject,actor: UserId) {
        val descriptor = DirectProfileDescriptor.decode(value);require(descriptor.peer != actor)
        if(descriptor.revision <= floor("security","",descriptor.peer.value)) return
        val old = db.rawQuery("SELECT user,revision,created,digest FROM direct_profile_bindings WHERE room=?",arrayOf(descriptor.room.value)).use {
            if(it.moveToFirst()) DirectProfileDescriptor(descriptor.room,UserId(it.getString(0)),it.getLong(1),it.getLong(2),it.getString(3)) else null
        }
        if(old != null) {
            require(old.peer == descriptor.peer && old.createdAt == descriptor.createdAt)
            if(old.revision > descriptor.revision) return
            if(old.revision == descriptor.revision) { require(old == descriptor.copy(accountKind=null));putAccountKind(descriptor.room,descriptor.peer,descriptor.revision,requireNotNull(descriptor.accountKind));return }
        }
        db.execSQL("INSERT OR REPLACE INTO direct_profile_bindings VALUES (?,?,?,?,?)",arrayOf<Any>(descriptor.room.value,descriptor.peer.value,descriptor.revision,descriptor.createdAt,descriptor.contentDigest))
        putAccountKind(descriptor.room,descriptor.peer,descriptor.revision,requireNotNull(descriptor.accountKind))
        put("profile","",descriptor.peer.value,descriptor.revision)
        invalidate()
    }
    fun peer(room:RoomId):UserId?=db.rawQuery("SELECT user,revision FROM direct_profile_bindings WHERE room=?",arrayOf(room.value)).use {
        if(it.moveToFirst() && it.getLong(1)>floor("security","",it.getString(0))) UserId(it.getString(0)) else null
    }
    fun accountKind(room:RoomId,peer:UserId):AccountKind?=db.rawQuery("SELECT revision,kind FROM direct_account_kinds WHERE room=? AND user=?",arrayOf(room.value,peer.value)).use {
        if(it.moveToFirst() && it.getLong(0)>floor("security","",peer.value) && it.getLong(0)>=floor("profile","",peer.value)) AccountKind.valueOf(it.getString(1)) else null
    }
    fun putAccountKind(room:RoomId,peer:UserId,revision:Long,kind:AccountKind) {
        require(revision>0)
        if(revision<=floor("security","",peer.value)) return
        db.rawQuery("SELECT user,revision,kind FROM direct_account_kinds WHERE room=?",arrayOf(room.value)).use {
            if(it.moveToFirst()) {
                require(it.getString(0)==peer.value)
                if(it.getLong(1)>revision) return
                if(it.getLong(1)==revision) {require(it.getString(2)==kind.name);return}
            }
        }
        db.execSQL("INSERT OR REPLACE INTO direct_account_kinds VALUES (?,?,?,?)",arrayOf(room.value,peer.value,revision,kind.name))
    }
    fun preserveDirectVersions() {
        db.rawQuery("SELECT user,MAX(revision) FROM direct_profile_bindings GROUP BY user",null).use { rows -> while(rows.moveToNext()) put("profile","",rows.getString(0),rows.getLong(1)) }
    }
    fun peers() = db.rawQuery("SELECT d.room,d.user FROM direct_profile_bindings d WHERE d.revision > COALESCE((SELECT f.revision FROM presentation_floors f WHERE f.kind='security' AND f.room='' AND f.user=d.user),0)",null).use { rows ->
        buildMap { while(rows.moveToNext()) put(RoomId(rows.getString(0)),UserId(rows.getString(1))) }.toPersistentMap()
    }
    fun generation() = db.rawQuery("SELECT value FROM presentation_epoch WHERE id=1",null).use { check(it.moveToFirst());it.getString(0) }
    fun invalidate() { db.execSQL("UPDATE presentation_epoch SET value=? WHERE id=1",arrayOf(UUID.randomUUID().toString())); changed() }
    fun read(keys: PersistentList<ProfileKey>): ProfileFenceSnapshot {
        require(keys.size <= 128)
        return ProfileFenceSnapshot(generation(),keys.associateWith { key ->
            val room = (key.context as? ProfileContext.Room)?.room?.value
            ProfileFence(floor("security","",key.user.value),floor("alias","",key.user.value),room?.let { floor("nickname",it,key.user.value) } ?: 0,floor("profile","",key.user.value))
        }.toPersistentMap())
    }
    private fun floor(kind: String,room: String,user: String) = db.rawQuery("SELECT revision FROM presentation_floors WHERE kind=? AND room=? AND user=?",arrayOf(kind,room,user)).use { if(it.moveToFirst()) it.getLong(0) else 0 }
    private fun put(kind: String,room: String,user: String,revision: Long) {
        if(revision <= floor(kind,room,user)) return
        db.execSQL("INSERT OR REPLACE INTO presentation_floors VALUES (?,?,?,?)",arrayOf<Any>(kind,room,user,revision));invalidate()
    }
    /** Returns true for privacy-safe invalidations, which must not retain unrecognized payload fields. */
    fun project(source: String,kind: String,value: JsonObject,sequence: Long?): Boolean {
        when(kind) {
            "profile_invalidation" -> {
                val user = id(value.text("user_id"));val revision = value.positive("minimum_profile_revision")
                require(value.text("profile_state") in setOf("hidden","deleted","suspended"))
                put("security","",user,revision);return true
            }
            "contact_alias" -> {
                require(value.keys == setOf("target_user_id","revision"))
                put("alias","",id(value.text("target_user_id")),value.positive("revision"));return true
            }
            "group_capability" -> if(value["event_type"]?.jsonPrimitive?.content == "group.nickname_changed") {
                require(value.keys == setOf("event_type","room_id","target_user_id","revision","room_sequence","server_created_at_ms"))
                val room = id(value.text("room_id"));val user = id(value.text("target_user_id"));val revision = value.positive("revision")
                val position = value.positive("room_sequence");require(sequence == null || sequence == position)
                val time = value.number("server_created_at_ms");require(time >= 0);val event = id(source.substringBefore('/'))
                db.rawQuery("SELECT source,user,revision,sequence,time FROM nickname_effects WHERE room=? AND (source=? OR (user=? AND revision=?) OR sequence=?)",arrayOf(room,event,user,revision.toString(),position.toString())).use { rows ->
                    while(rows.moveToNext()) require(rows.getString(0) == event && rows.getString(1) == user && rows.getLong(2) == revision && rows.getLong(3) == position && rows.getLong(4) == time)
                }
                db.rawQuery("SELECT revision,sequence FROM nickname_effects WHERE room=? AND user=? ORDER BY revision DESC LIMIT 1",arrayOf(room,user)).use { rows ->
                    if(rows.moveToFirst()) require(when { revision < rows.getLong(0) -> position < rows.getLong(1);revision > rows.getLong(0) -> position > rows.getLong(1);else -> position == rows.getLong(1) })
                }
                db.execSQL("INSERT OR IGNORE INTO nickname_effects VALUES (?,?,?,?,?,?)",arrayOf<Any>(event,room,user,revision,position,time))
                put("nickname",room,user,revision);return true
            }
        }
        if(kind in setOf("relationship","user_block","room","membership","direct_room_profile") || kind == "group_capability" && value["event_type"]?.jsonPrimitive?.content in setOf("group.member_role_changed","group.role_permissions_changed")) invalidate()
        return false
    }
    fun ownProfileConfirmed(actor: UserId,revision: Long) { require(revision > 0);put("profile","",actor.value,revision) }
    fun nameConfirmed(value: NameSnapshot) {
        val revision = value.revision ?: return
        when(val target = value.target) {
            is NameTarget.Contact -> put("alias","",target.user.value,revision)
            is NameTarget.Group -> put("nickname",target.room.value,value.actor.value,revision)
        }
    }
    fun purge(room: String) {
        db.execSQL("DELETE FROM direct_account_kinds WHERE room=?",arrayOf(room))
        db.execSQL("DELETE FROM direct_profile_bindings WHERE room=?",arrayOf(room))
        db.execSQL("DELETE FROM presentation_floors WHERE room=?",arrayOf(room));db.execSQL("DELETE FROM nickname_effects WHERE room=?",arrayOf(room));invalidate()
    }
    private fun id(raw: String): String = UUID.fromString(raw).toString().uppercase().also { require(it.equals(raw,true)) }
    private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
    private fun JsonObject.number(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
    private fun JsonObject.positive(key: String) = number(key).also { require(it > 0) }
}
