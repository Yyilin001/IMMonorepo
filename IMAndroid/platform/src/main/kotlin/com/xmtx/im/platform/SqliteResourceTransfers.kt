package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList

/** Read/action calls share the account writer transaction. No JSON1 extension is needed on API 31. */
internal class SqliteResourceTransfers(private val db:SQLiteDatabase,private val files:SqliteResourceFiles,
    private val imports:SqliteResourceImports,private val downloads:SqliteResourceDownloads,private val sends:SqliteSendIntents) {
    private fun owners(id:ResourceTransferId,asset:String?=null):Boolean {
        if(id.kind==ResourceTransferKind.Download) return false
        val column=if(id.kind==ResourceTransferKind.Upload) "upload_id" else "import_id"
        val attachment=if(id.kind==ResourceTransferKind.Upload) "send_intent_attachments" else "send_intent_imports"
        if(db.rawQuery("SELECT 1 FROM profile_intents WHERE $column=? UNION ALL SELECT 1 FROM group_avatar_intents WHERE $column=? UNION ALL SELECT 1 FROM $attachment WHERE $column=? LIMIT 1",arrayOf(id.value,id.value,id.value)).use {it.moveToFirst()}) return true
        // Source claims also protect an owner between adopting a source and preparing its upload.
        return if(asset!=null) db.rawQuery("SELECT 1 FROM resource_source_claims WHERE asset=? LIMIT 1",arrayOf(asset)).use {it.moveToFirst()}
        else db.rawQuery("SELECT 1 FROM resource_import_consumers WHERE import_id=? LIMIT 1",arrayOf(id.value)).use {it.moveToFirst()}
    }
    private fun visibleOwners(id:ResourceTransferId):Boolean {
        if(id.kind==ResourceTransferKind.Download) return false
        val column=if(id.kind==ResourceTransferKind.Upload) "upload_id" else "import_id"
        val attachment=if(id.kind==ResourceTransferKind.Upload) "send_intent_attachments" else "send_intent_imports"
        return db.rawQuery("SELECT 1 FROM profile_intents WHERE $column=? AND owner_live=1 UNION ALL SELECT 1 FROM group_avatar_intents WHERE $column=? AND owner_live=1 UNION ALL SELECT 1 FROM $attachment WHERE $column=? LIMIT 1",arrayOf(id.value,id.value,id.value)).use {it.moveToFirst()}
    }
    internal sealed interface UnboundIdentity {
        data class Upload(val request:ResourceUploadRequest,val asset:String):UnboundIdentity
        data class Import(val request:ResourceImportRequest):UnboundIdentity
    }
    fun unboundIdentity(id:ResourceTransferId):UnboundIdentity? = when(id.kind) {
        ResourceTransferKind.Download->null
        ResourceTransferKind.Upload->files.upload(id.value)?.takeIf {!it.terminal && !it.cancellationRequested && !owners(id,it.asset)}?.let {UnboundIdentity.Upload(it.request,it.asset)}
        ResourceTransferKind.ServerImport->imports.find(id.value)?.takeIf {
            !it.terminal && !it.cancellationRequested && !it.businessBound && it.request.targetUsage is ResourceUsage.Attachment && !owners(id)
        }?.let {UnboundIdentity.Import(it.request)}
    }
    fun cancelUnbound(id:ResourceTransferId,reviewed:UnboundIdentity) {
        if(unboundIdentity(id)!=reviewed) throw ResourceTransferActionUnavailable()
        when(id.kind) {
            ResourceTransferKind.Upload->files.cancel(id.value)
            ResourceTransferKind.ServerImport->imports.cancel(id.value)
            ResourceTransferKind.Download->throw ResourceTransferActionUnavailable()
        }
    }
    fun row(id:ResourceTransferId,now:Long):ManagedResourceTransfer? {
        val value=when(id.kind) {
        ResourceTransferKind.Upload->files.upload(id.value)?.let {work->
            val created=db.rawQuery("SELECT created FROM resource_uploads WHERE id=?",arrayOf(id.value)).use {it.moveToFirst();it.getLong(0)}
            ResourceTransferProjection.upload(work,created,owners(id,work.asset),now)
        }
        ResourceTransferKind.ServerImport->imports.find(id.value)?.let {ResourceTransferProjection.serverImport(it,owners(id),now)}
        ResourceTransferKind.Download->downloads.snapshot(id.value)?.let {ResourceTransferProjection.download(it,now)}
        } ?: return null
        val displayed=value.copy(hasBusinessOwners=visibleOwners(id))
        val count=sends.preparationCancellationParents(id)?.size
        return if(count==null) displayed else displayed.copy(actions=value.actions.add(ResourceTransferAction.CancelPreparation),cancellableMessageCount=count)
    }
    fun page(query:ResourceTransferQuery,now:Long,checkActive:()->Unit):ResourceTransferPage {
        require(now>=0)
        val result=ArrayList<ManagedResourceTransfer>();var cursor=query.before
        // Scan canonical IDs in bounded chunks. Filtering never loads all journal payloads into a snapshot.
        // Retry/progress changes do not alter the creation-time cursor.
        while(result.size<=query.limit) {
            checkActive()
            val args=mutableListOf<String>()
            val branches=ResourceTransferKind.entries.map {kind->
                val table=when(kind) {ResourceTransferKind.Upload->"resource_uploads";ResourceTransferKind.Download->"resource_downloads";ResourceTransferKind.ServerImport->"resource_imports"}
                val filter=cursor?.let {args+=listOf(it.createdAt.toString(),it.id.kind.key,it.id.value);" WHERE (created,'${kind.key}',id)<(?,?,?)"} ?: ""
                "SELECT created,'${kind.key}' AS kind,id FROM $table$filter"
            }
            val keys=db.rawQuery(branches.joinToString(" UNION ALL ")+" ORDER BY created DESC,kind DESC,id DESC LIMIT 100",args.toTypedArray()).use {rows->buildList {
                while(rows.moveToNext()) add(ResourceTransferCursor(rows.getLong(0),ResourceTransferId(ResourceTransferKind.entries.first {it.key==rows.getString(1)},rows.getString(2))))
            }}
            if(keys.isEmpty()) break
            for(key in keys) {
                checkActive();val value=checkNotNull(row(key.id,now))
                if(query.group==null || value.group==query.group) result+=value
                if(result.size>query.limit) break
            }
            cursor=keys.last()
            if(keys.size<100) break
        }
        val entries=result.take(query.limit).toPersistentList()
        return ResourceTransferPage(entries,entries.lastOrNull()?.cursor.takeIf {result.size>query.limit})
    }
    fun control(id:ResourceTransferId,action:ResourceTransferAction,now:Long) {
        require(now>=0)
        val current=row(id,now) ?: throw ResourceTransferActionUnavailable()
        if(action !in current.actions || action in setOf(ResourceTransferAction.CancelPreparation,ResourceTransferAction.CancelUnbound)) throw ResourceTransferActionUnavailable()
        when(id.kind) {
            ResourceTransferKind.Upload->files.control(id.value,action==ResourceTransferAction.Pause,action in setOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation) || action==ResourceTransferAction.Resume)
            ResourceTransferKind.ServerImport->imports.control(id.value,action==ResourceTransferAction.Pause,action in setOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation) || action==ResourceTransferAction.Resume)
            ResourceTransferKind.Download->downloads.control(id.value,when(action) {ResourceTransferAction.Pause->ResourceDownloadControl.Pause;ResourceTransferAction.Cancel->ResourceDownloadControl.Cancel;else->ResourceDownloadControl.Run},now)
        }
    }
}
