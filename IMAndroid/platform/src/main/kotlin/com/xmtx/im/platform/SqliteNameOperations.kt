package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*

/** Caller holds the parent store mutex and transaction. Editable fields are not display leases. */
internal class SqliteNameOperations(private val db: SQLiteDatabase,private val actor: UserId,private val profiles: SqliteProfilePresentations) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS name_operations (id TEXT PRIMARY KEY,target TEXT NOT NULL,work TEXT NOT NULL CHECK(length(work)<=131072))")
        db.execSQL("CREATE TABLE IF NOT EXISTS name_confirmed (target TEXT PRIMARY KEY,value TEXT NOT NULL CHECK(length(value)<=65536))")
    } }
    fun works(): PersistentList<NameWork> = db.rawQuery("SELECT work FROM name_operations ORDER BY rowid",null).use { rows ->
        buildList { while(rows.moveToNext()) add(Json.decodeFromString<NameWork>(rows.getString(0)).also { require(it.command.actor == actor) }) }.toPersistentList()
    }
    private fun floor(target: NameTarget) = when(target) {
        is NameTarget.Contact -> profiles.read(persistentListOf(ProfileKey(target.user,ProfileContext.Relationship))).floors.values.single().aliasRevision
        is NameTarget.Group -> profiles.read(persistentListOf(ProfileKey(actor,ProfileContext.Room(target.room)))).floors.values.single().nicknameRevision
    }
    private fun stored(target: NameTarget): NameSnapshot? = db.rawQuery("SELECT value FROM name_confirmed WHERE target=?",arrayOf(target.key)).use {
        if(it.moveToFirst()) Json.decodeFromString<NameSnapshot>(it.getString(0)).also { value -> require(value.actor == actor && value.target == target) } else null
    }
    fun snapshots(): PersistentList<NameSnapshot> = db.rawQuery("SELECT value FROM name_confirmed ORDER BY target",null).use { rows ->
        buildList { while(rows.moveToNext()) {
            val value = Json.decodeFromString<NameSnapshot>(rows.getString(0));require(value.actor == actor)
            if((value.revision ?: 0) >= floor(value.target)) add(value)
        } }.toPersistentList()
    }
    fun save(value: NameSnapshot): NameSnapshot? {
        require(value.actor == actor)
        val old = stored(value.target)
        if(old != null && old.revision == value.revision) require(old == value)
        if(old == null || (value.revision ?: 0) > (old.revision ?: 0)) {
            db.execSQL("INSERT OR REPLACE INTO name_confirmed VALUES (?,?)",arrayOf(value.target.key,Json.encodeToString(value)))
            profiles.nameConfirmed(value)
        }
        return stored(value.target)?.takeIf { (it.revision ?: 0) >= floor(value.target) }
    }
    fun enqueue(command: NameCommand): NameWork {
        require(command.actor == actor)
        val baseline = stored(command.target) ?: error("请先刷新当前名称")
        require(baseline.revision == command.revision && (baseline.revision ?: 0) >= floor(command.target)) { "名称版本已变化，请刷新后重试" }
        val all = works();check(all.none { !it.terminal && it.command.target == command.target }) { "请先确认前一笔修改" }
        all.filter { it.terminal }.dropLast(127).forEach { db.execSQL("DELETE FROM name_operations WHERE id=? AND NOT EXISTS(SELECT 1 FROM operation_work WHERE operation_work.id=name_operations.id)",arrayOf(it.command.operation)) }
        val work = NameWork(command)
        db.execSQL("INSERT INTO name_operations VALUES (?,?,?)",arrayOf(command.operation,command.target.key,Json.encodeToString(work)))
        return work
    }
    fun update(expected: NameWork,updated: NameWork) {
        require(expected.command == updated.command && expected.command.actor == actor && !expected.terminal)
        check(works().firstOrNull { it.command.operation == expected.command.operation } == expected)
        require(!expected.submissionStarted || updated.submissionStarted)
        require(!expected.closeRequested || updated.closeRequested)
        var persisted = updated
        if(updated.status == NameStatus.Cancelled) require(!updated.submissionStarted && updated.receipt == null)
        else if(updated.terminal) {
            require(updated.submissionStarted)
            val receipt = NameOperationClient.decodeReceipt(updated.command,Json.parseToJsonElement(requireNotNull(updated.receipt)).jsonObject)
            require(receipt.status == updated.status && receipt.reason == updated.reason)
            receipt.snapshot?.let { save(it) }
            persisted = updated.copy(receipt = receipt.wire)
        } else require(updated.receipt == null)
        db.execSQL("UPDATE name_operations SET work=? WHERE id=?",arrayOf(Json.encodeToString(persisted),updated.command.operation))
    }
}
