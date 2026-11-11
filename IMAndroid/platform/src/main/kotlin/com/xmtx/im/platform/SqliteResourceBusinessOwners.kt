package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.Json

/** Indexed live-owner projection, validated against canonical account-owned payloads. */
internal class SqliteResourceBusinessOwners(private val db:SQLiteDatabase,private val actor:UserId,private val device:DeviceId) {
    private fun selection(transfer:ResourceTransferId):String? {
        if(transfer.kind==ResourceTransferKind.Download) return null
        val column=if(transfer.kind==ResourceTransferKind.Upload) "upload_id" else "import_id"
        return "SELECT 'profile' kind,id,created,NULL room,payload FROM profile_intents WHERE $column=? AND owner_live=1 UNION ALL SELECT 'group' kind,id,created,room,payload FROM group_avatar_intents WHERE $column=? AND owner_live=1"
    }
    private fun read(rows:Cursor,transfer:ResourceTransferId):ResourceBusinessOwnerEntry {
        val id=rows.getString(1);val created=rows.getLong(2)
        val owner=when(rows.getString(0)) {
            "profile"->{
                val value=Json.decodeFromString<ProfileIntent>(rows.getString(4))
                require(value.actor==actor && value.id==id && !value.sourceReleased && (value.deadline-86400000).coerceAtLeast(0)==created)
                require(if(transfer.kind==ResourceTransferKind.Upload) value.upload?.id==transfer.value else value.serverImport?.id==transfer.value)
                ResourceBusinessOwner.Profile(id)
            }
            "group"->{
                val value=Json.decodeFromString<GroupAvatarIntent>(rows.getString(4));val room=RoomId(rows.getString(3))
                require(value.actor==actor && value.device==device && value.id==id && value.command.room==room && value.createdAt==created && value.pending)
                require(if(transfer.kind==ResourceTransferKind.Upload) value.upload==transfer.value else value.serverImport?.id==transfer.value)
                ResourceBusinessOwner.Group(room,id)
            }
            else->error("Unknown resource owner")
        }
        return ResourceBusinessOwnerEntry(owner,created)
    }
    fun page(query:ResourceBusinessOwnerQuery):ResourceBusinessOwnerPage {
        val selection=selection(query.transfer) ?: return ResourceBusinessOwnerPage(persistentListOf())
        val args=mutableListOf(query.transfer.value,query.transfer.value)
        val predicate=query.before?.let {args+=listOf(it.createdAt.toString(),it.kind,it.id);" WHERE (created,kind,id)<(?,?,?)"} ?: ""
        args+=(query.limit+1).toString()
        val rows=db.rawQuery("SELECT * FROM ($selection)$predicate ORDER BY created DESC,kind DESC,id DESC LIMIT ?",args.toTypedArray()).use {r->buildList {while(r.moveToNext()) add(read(r,query.transfer))}}
        val entries=rows.take(query.limit).toPersistentList()
        val next=entries.lastOrNull()?.takeIf {rows.size>query.limit}?.let {ResourceBusinessOwnerCursor(query.transfer,it.createdAt,it.owner.kind,it.owner.id)}
        return ResourceBusinessOwnerPage(entries,next)
    }
    fun contains(transfer:ResourceTransferId,owner:ResourceBusinessOwner):Boolean {
        val selection=selection(transfer) ?: return false
        val args=arrayOf(transfer.value,transfer.value,owner.kind,owner.id)
        return db.rawQuery("SELECT * FROM ($selection) WHERE kind=? AND id=? LIMIT 1",args).use {it.moveToFirst() && read(it,transfer).owner==owner}
    }
}
