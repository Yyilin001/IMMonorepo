package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*

/** Own editable snapshot is durable; neither this table nor its receipts authorize avatar downloads. */
internal class SqliteOwnProfile(private val db: SQLiteDatabase,private val actor: UserId,private val profiles: SqliteProfilePresentations, private val registerExecution: (OwnProfileWork, Long?) -> Unit) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS own_profile (id INTEGER PRIMARY KEY CHECK(id=1),value TEXT NOT NULL CHECK(length(value)<=65536))")
        db.execSQL("CREATE TABLE IF NOT EXISTS own_profile_operations (id TEXT PRIMARY KEY,work TEXT NOT NULL CHECK(length(work)<=131072))")
    } }
    private fun stored() = db.rawQuery("SELECT value FROM own_profile WHERE id=1",null).use {
        if(it.moveToFirst()) OwnProfileClient.decodeProfile(actor,Json.parseToJsonElement(it.getString(0)).jsonObject) else null
    }
    fun read(): ProfileView? {
        val value = stored() ?: return null
        val floor = profiles.read(persistentListOf(ProfileKey(actor,ProfileContext.Relationship))).floors.values.single()
        return value.takeIf { it.revision >= floor.minimumProfileRevision && (it.revision > floor.securityRevision || it.revision == floor.securityRevision && it.state != ProfileState.Active) }
    }
    fun save(value: ProfileView): ProfileView? {
        val wire = OwnProfileClient.profilePayload(value);require(OwnProfileClient.decodeProfile(actor,wire) == value)
        val old = stored()
        if(old != null) {
            if(old.revision == value.revision) require(old == value) { "同版本资料内容冲突" }
            if(value.revision < old.revision) { require(value.visibilityRevision <= old.visibilityRevision);return read() }
            require(value.visibilityRevision >= old.visibilityRevision)
        }
        if(old != value) {
            db.execSQL("INSERT OR REPLACE INTO own_profile VALUES (1,?)",arrayOf(wire.toString()))
            profiles.ownProfileConfirmed(actor,value.revision)
        }
        return read()
    }
    fun works(): PersistentList<OwnProfileWork> = db.rawQuery("SELECT work FROM own_profile_operations ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<OwnProfileWork>(rows.getString(0)).also { require(it.command.actor == actor) }) }.toPersistentList()
    }
    fun enqueue(command: OwnProfileCommand,replaces: String?,requireCurrentBaseline: Boolean=true, now: Long? = null): OwnProfileWork {
        require(command.actor == actor)
        if(requireCurrentBaseline) {
            val baseline = read() ?: error("请先刷新本人资料")
            require(baseline.state == ProfileState.Active && baseline.revision == command.revision) { "资料版本已变化，请刷新后重试" }
        }
        val all = works()
        val source = replaces?.let { id -> all.first { it.command.operation == id }.also {
            require(it.terminal && it.draftRetained && it.status != OwnProfileStatus.Committed && it.command.patch == command.patch)
        } }
        // Unresolved identities and explicitly retained drafts cannot be evicted.
        all.filter { it.terminal && !it.draftRetained }.dropLast(127).forEach { db.execSQL("DELETE FROM own_profile_operations WHERE id=? AND NOT EXISTS(SELECT 1 FROM profile_intents WHERE operation=own_profile_operations.id) AND NOT EXISTS(SELECT 1 FROM operation_work WHERE id=own_profile_operations.id)",arrayOf(it.command.operation)) }
        check(all.count { it.draftRetained } < 128 || source != null) { "请先处理保留的资料草稿" }
        val work = OwnProfileWork(command)
        db.execSQL("INSERT INTO own_profile_operations VALUES (?,?)",arrayOf(command.operation,Json.encodeToString(work)))
        registerExecution(work, now)
        source?.let { put(it.copy(draftRetained = false)) }
        return work
    }
    private fun put(work: OwnProfileWork) { db.execSQL("UPDATE own_profile_operations SET work=? WHERE id=?",arrayOf(Json.encodeToString(work),work.command.operation)) }
    fun update(expected: OwnProfileWork,updated: OwnProfileWork) {
        require(expected.command.actor == actor && expected.command == updated.command && !expected.terminal)
        check(works().firstOrNull { it.command.operation == expected.command.operation } == expected)
        require(!expected.submissionStarted || updated.submissionStarted)
        var persisted = updated
        if(updated.status == OwnProfileStatus.Expired) require(!updated.submissionStarted && updated.receipt == null && updated.draftRetained)
        else if(updated.terminal) {
            require(updated.submissionStarted)
            val receipt = OwnProfileClient.decodeResult(updated.command,Json.parseToJsonElement(requireNotNull(updated.receipt)).jsonObject)
            require(receipt.status == updated.status && receipt.reason == updated.reason && updated.draftRetained == (receipt.status != OwnProfileStatus.Committed))
            receipt.snapshot?.let { save(it) }
            receipt.revision?.let { profiles.ownProfileConfirmed(actor,it) }
            receipt.conflictRevision?.let { profiles.ownProfileConfirmed(actor,it) }
            persisted = updated.copy(receipt = receipt.wire)
        } else require(updated.receipt == null && updated.draftRetained)
        put(persisted)
    }
    fun discard(operation: String) {
        val work = works().first { it.command.operation == operation };require(work.terminal && work.draftRetained)
        put(work.copy(draftRetained = false))
    }
}
