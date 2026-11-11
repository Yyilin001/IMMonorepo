package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.util.UUID

/** All methods run within the parent store's mutex and transaction. No network or mutable UI state. */
internal class SqlitePolicyRecovery(private val db: SQLiteDatabase,private val actor: UserId,private val device: DeviceId, private val snapshotPending: () -> Boolean) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS policy_profile_fences (room TEXT PRIMARY KEY,revision INTEGER NOT NULL,source TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS policy_baselines (room TEXT PRIMARY KEY,value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS policy_denials (room TEXT PRIMARY KEY)")
        db.execSQL("CREATE TABLE IF NOT EXISTS policy_recovery (room TEXT PRIMARY KEY,generation INTEGER NOT NULL,membership INTEGER NOT NULL,source TEXT NOT NULL,grant_revision INTEGER NOT NULL,grant_source TEXT NOT NULL,state TEXT NOT NULL,next INTEGER NOT NULL,work TEXT NOT NULL)")
        db.execSQL("CREATE INDEX IF NOT EXISTS policy_recovery_due ON policy_recovery(state,next,room)")
        db.execSQL("CREATE TABLE IF NOT EXISTS policy_schema (version INTEGER PRIMARY KEY)")
        if(db.rawQuery("SELECT 1 FROM policy_schema WHERE version=1",null).use { !it.moveToFirst() }) {
            db.beginTransaction()
            try {
        // Upgrade old projections without claiming an unobserved permission baseline.
        db.rawQuery("SELECT event,payload FROM records WHERE kind IN ('room','membership') AND room NOT IN (SELECT room FROM memberships WHERE member=0)",null).use { rows -> while(rows.moveToNext()) {
            val value = Json.parseToJsonElement(rows.getBlob(1).toString(Charsets.UTF_8)).jsonObject
            val room = value["room_id"]?.jsonPrimitive?.content?.let { RoomId(it) } ?: continue
            val revision = value["membership_revision"]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: continue
            if(revision > 0) observeProfile(room,revision,rows.getString(0).substringBefore('/'))
        } }
        db.execSQL("INSERT OR IGNORE INTO policy_profile_fences SELECT room,revision,source FROM memberships WHERE member=1 AND revision>0")
                db.execSQL("INSERT INTO policy_schema VALUES (1)");db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        }
    } }
    private fun ready() { if(waiting()) throw PolicyRecoverySyncPending() }
    private fun waiting() = snapshotPending()
    private fun generation() = db.rawQuery("SELECT generation FROM cursor WHERE id=1",null).use { check(it.moveToFirst());maxOf(1,it.integer(0,0)) }
    fun observeProfile(room: RoomId,revision: Long,source: String) {
        require(revision > 0 && source.isNotBlank())
        val old = db.rawQuery("SELECT revision,source FROM policy_profile_fences WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) it.integer(0) to it.getString(1) else null }
        if(old != null && (old.first > revision || old.first == revision && old.second != "state")) return
        db.execSQL("INSERT OR REPLACE INTO policy_profile_fences VALUES (?,?,?)",arrayOf<Any>(room.value,revision,source))
    }
    fun authorizedState(room: RoomId,revision: Long) {
        db.execSQL("DELETE FROM policy_denials WHERE room=?",arrayOf(room.value))
        if(revision > 0) observeProfile(room,revision,"state")
    }
    private fun binding(room: RoomId): PolicyRecoveryBinding? = db.rawQuery("""SELECT f.revision,f.source,m.revision,m.source FROM policy_profile_fences f
        JOIN memberships m ON m.room=f.room AND m.member=1 JOIN rooms r ON r.id=f.room JOIN room_kinds k ON k.room=f.room AND k.kind='Group'
        WHERE f.room=? AND f.room NOT IN (SELECT room FROM policy_denials)""",arrayOf(room.value)).use { rows ->
        if(!rows.moveToFirst()) null else PolicyRecoveryBinding(actor,device,room,generation(),rows.integer(0),rows.getString(1),rows.integer(2),rows.getString(3))
    }
    private fun requestNow(room: RoomId) = db.rawQuery("SELECT work FROM policy_recovery WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) Json.decodeFromString<PolicyRecoveryRequest>(it.getString(0)) else null }
    private fun save(work: PolicyRecoveryRequest) { val b = work.binding
        db.execSQL("INSERT OR REPLACE INTO policy_recovery VALUES (?,?,?,?,?,?,?,?,?)",arrayOf<Any>(work.room.value,b.generation,b.membership,b.source,b.grant,b.grantSource,if(work.paused) "paused" else "pending",work.nextAttempt,Json.encodeToString(work)))
    }
    fun request(room: RoomId,resume: Boolean): PolicyRecoveryRequest {
        ready();val binding = binding(room) ?: throw PolicyRecoveryUnauthorized()
        val old = requestNow(room)
        if(!resume && old?.binding == binding) return old
        return PolicyRecoveryRequest(UUID.randomUUID().toString().uppercase(),binding).also(::save)
    }
    fun discover(limit: Int): Int {
        require(limit in 1..100);ready()
        db.execSQL("DELETE FROM policy_recovery WHERE room IN (SELECT room FROM policy_recovery WHERE room NOT IN (SELECT m.room FROM memberships m JOIN rooms r ON r.id=m.room JOIN room_kinds k ON k.room=m.room AND k.kind='Group' WHERE m.member=1) ORDER BY room LIMIT ?)",arrayOf(limit))
        val rooms = db.rawQuery("""SELECT r.id FROM rooms r JOIN room_kinds k ON k.room=r.id AND k.kind='Group'
            JOIN memberships m ON m.room=r.id AND m.member=1 JOIN policy_profile_fences f ON f.room=r.id
            LEFT JOIN policy_baselines b ON b.room=r.id LEFT JOIN policy_recovery q ON q.room=r.id
            WHERE r.id NOT IN (SELECT room FROM policy_denials) AND ((b.room IS NULL AND q.room IS NULL) OR q.generation<>? OR q.membership<>f.revision OR q.source<>f.source OR q.grant_revision<>m.revision OR q.grant_source<>m.source)
            ORDER BY r.id LIMIT ?""",arrayOf(generation().toString(),limit.toString())).use { rows -> buildList { while(rows.moveToNext()) add(RoomId(rows.getString(0))) } }
        rooms.forEach { request(it,false) };return rooms.size
    }
    fun due(now: Long,limit: Int): PersistentList<PolicyRecoveryRequest> {
        require(now >= 0 && limit in 1..100);ready()
        return db.rawQuery("SELECT work FROM policy_recovery WHERE state='pending' AND next<=? ORDER BY next,room LIMIT ?",arrayOf(now.toString(),limit.toString())).use { rows ->
            buildList { while(rows.moveToNext()) add(Json.decodeFromString<PolicyRecoveryRequest>(rows.getString(0))) }.toPersistentList()
        }
    }
    private fun matches(request: PolicyRecoveryRequest) = requestNow(request.room) == request && binding(request.room) == request.binding
    private fun baseline(room: RoomId) = db.rawQuery("SELECT value FROM policy_baselines WHERE room=?",arrayOf(room.value)).use { if(it.moveToFirst()) Json.decodeFromString<GroupPolicies>(it.getString(0)) else null }
    private fun observed(room: RoomId) = db.rawQuery("SELECT effect FROM role_policy_observations WHERE room=? ORDER BY role",arrayOf(room.value)).use { rows -> buildList { while(rows.moveToNext()) add(Json.decodeFromString<RolePolicyEffect>(rows.getString(0))) } }
    fun complete(request: PolicyRecoveryRequest,value: GroupPolicies): Boolean {
        ready();if(!matches(request)) return false
        if(value.room != request.room || value.membershipRevision < request.binding.membership) throw ClientFailure.Protocol()
        val previous = baseline(request.room)
        if(previous != null && previous.revision == value.revision && (previous.admin != value.admin || previous.member != value.member)) throw ClientFailure.Protocol()
        if(previous != null && previous.revision > value.revision) return false
        val replace = previous == null || previous.revision != value.revision || value.membershipRevision > previous.membershipRevision || value.roomSequence > previous.roomSequence
        if(replace) {
            if(previous != null && (value.membershipRevision < previous.membershipRevision || value.roomSequence < previous.roomSequence)) throw ClientFailure.Protocol()
            observed(request.room).filter { it.revision == value.revision }.forEach { effect ->
                if(effect.permissions != if(effect.role == MemberRole.Admin) value.admin else value.member) throw ClientFailure.Protocol()
            }
            db.execSQL("INSERT OR REPLACE INTO policy_baselines VALUES (?,?)",arrayOf(value.room.value,Json.encodeToString(value)))
        }
        db.execSQL("DELETE FROM policy_recovery WHERE room=?",arrayOf(request.room.value));return true
    }
    fun failure(request: PolicyRecoveryRequest,disposition: PolicyRecoveryDisposition): Boolean {
        ready();if(!matches(request)) return false
        when(disposition) {
            PolicyRecoveryDisposition.Unauthorized -> {
                db.execSQL("INSERT OR IGNORE INTO policy_denials VALUES (?)",arrayOf(request.room.value))
                db.execSQL("DELETE FROM policy_baselines WHERE room=?",arrayOf(request.room.value));db.execSQL("DELETE FROM policy_recovery WHERE room=?",arrayOf(request.room.value))
            }
            PolicyRecoveryDisposition.Pause -> save(request.copy(paused = true,attempts = if(request.attempts == Int.MAX_VALUE) Int.MAX_VALUE else request.attempts+1))
            is PolicyRecoveryDisposition.Retry -> save(request.copy(nextAttempt = disposition.at,attempts = if(request.attempts == Int.MAX_VALUE) Int.MAX_VALUE else request.attempts+1))
        };return true
    }
    /** Called before installing an event; a baseline must never be silently contradicted at the same revision. */
    fun validateEvent(effect: RolePolicyEffect): Boolean {
        val baseline = baseline(effect.room) ?: return true
        if(effect.revision == baseline.revision && effect.permissions != if(effect.role == MemberRole.Admin) baseline.admin else baseline.member) throw ClientFailure.Protocol()
        return effect.revision > baseline.revision
    }
    fun states(): PersistentList<GroupPolicyState> = db.rawQuery("SELECT r.id FROM rooms r JOIN room_kinds k ON k.room=r.id AND k.kind='Group' ORDER BY r.id",null).use { rows ->
        buildList { while(rows.moveToNext()) {
            val room = RoomId(rows.getString(0));val binding = binding(room)
            if(binding == null) { add(GroupPolicyState(room,persistentListOf(),PolicyRecoveryStatus.Unavailable));continue }
            val baseline = baseline(room);val effects = observed(room);val revision = maxOf(baseline?.revision ?: 1,effects.maxOfOrNull { it.revision } ?: 1)
            val policies = listOf(MemberRole.Admin,MemberRole.Member).mapNotNull { role ->
                val effect = effects.firstOrNull { it.role == role }
                val permissions = if(baseline != null && (effect == null || effect.revision <= baseline.revision)) { if(role == MemberRole.Admin) baseline.admin else baseline.member } else effect?.permissions
                permissions?.let { LocalRolePolicy(room,role,it,revision) }
            }.toPersistentList()
            val request = requestNow(room)
            val status = when {
                waiting() -> PolicyRecoveryStatus.WaitingForSync
                request != null && request.binding != binding -> PolicyRecoveryStatus.Needed
                request?.paused == true -> PolicyRecoveryStatus.Paused
                request != null -> PolicyRecoveryStatus.Pending
                baseline != null -> PolicyRecoveryStatus.Ready
                else -> PolicyRecoveryStatus.Needed
            }
            add(GroupPolicyState(room,policies,status,request?.nextAttempt?.takeIf { status == PolicyRecoveryStatus.Pending },baseline?.membershipRevision))
        } }.toPersistentList()
    }
}
private fun Cursor.integer(index: Int,minimum: Long = 1): Long {
    if(getType(index) != Cursor.FIELD_TYPE_INTEGER || getLong(index) < minimum) throw ClientFailure.Protocol()
    return getLong(index)
}
