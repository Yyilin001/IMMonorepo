package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/** Selections remain durable draft owners until the send transaction adopts them. */
internal class SqliteConversationDrafts(private val db: SQLiteDatabase,private val resources: SqliteResourceFiles,private val sends: SqliteSendIntents,private val currentSource: (MessageAttachmentSelection)->Boolean,private val revoked: (String)->Boolean,private val sendingRestriction: (RoomId)->String?) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS conversation_drafts(room TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(length(payload)<=524288))")
        val schema = db.rawQuery("SELECT sql FROM sqlite_master WHERE type='table' AND name='conversation_drafts'", null).use { it.moveToFirst(); it.getString(0) }
        if (schema.contains("131072")) {
            val definitions = db.rawQuery("SELECT sql FROM sqlite_master WHERE tbl_name='conversation_drafts' AND type IN ('index','trigger') AND sql IS NOT NULL", null).use { rows ->
                buildList { while (rows.moveToNext()) add(rows.getString(0)) }
            }
            db.execSQL("CREATE TABLE conversation_drafts_text_v2(room TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(length(payload)<=524288))")
            db.execSQL("INSERT INTO conversation_drafts_text_v2 SELECT room,payload FROM conversation_drafts")
            db.execSQL("DROP TABLE conversation_drafts")
            db.execSQL("ALTER TABLE conversation_drafts_text_v2 RENAME TO conversation_drafts")
            definitions.forEach(db::execSQL)
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS conversation_draft_submissions(room TEXT NOT NULL,revision INTEGER NOT NULL,intent TEXT UNIQUE NOT NULL,PRIMARY KEY(room,revision))")
    } }
    fun read(room: RoomId): ConversationDraft=db.rawQuery("SELECT payload FROM conversation_drafts WHERE room=?",arrayOf(room.value)).use {
        if(it.moveToFirst()) Json.decodeFromString<ConversationDraft>(it.getString(0)).also { draft -> require(draft.room==room) } else ConversationDraft(room)
    }
    /** Recover a photo published immediately before process death, before its draft-row adoption. */
    fun restore(room: RoomId): ConversationDraft {
        val current=read(room)
        val known=current.attachments.map { it.asset }.toSet()
        val recovered=resources.assets().filter { it.selectionActive && it.purpose==ResourceUsage.Attachment(room) && it.availability!=ResourceAssetAvailability.Importing && it.id !in known }
            .take(10-current.attachmentOrder.size).map { SendAttachment(it.id,it.id,it.displayName,it.contentType,it.byteCount) }
        if(recovered.isEmpty()) return current
        return put(current.copy(revision=Math.addExact(current.revision,1),attachments=current.attachments.addAll(recovered),attachmentOrder=current.attachmentOrder.addAll(recovered.map {it.id}),updatedAt=System.currentTimeMillis()))
    }
    private fun requireCanSend(room:RoomId) {val restriction=sendingRestriction(room);check(restriction==null) {requireNotNull(restriction)}}
    private fun requireCurrent(expected: ConversationDraft) { if(read(expected.room)!=expected) throw ConversationDraftConflict() }
    private fun put(value: ConversationDraft): ConversationDraft {
        if(!value.empty) {
            val active=db.rawQuery("SELECT payload FROM conversation_drafts WHERE room<>?",arrayOf(value.room.value)).use { rows -> var count=0;while(rows.moveToNext()) if(!Json.decodeFromString<ConversationDraft>(rows.getString(0)).empty) count++;count }
            check(active<256) { "保留的会话草稿过多，请先清理部分草稿" }
        }
        db.execSQL("INSERT OR REPLACE INTO conversation_drafts VALUES (?,?)",arrayOf(value.room.value,Json.encodeToString(value)));return value
    }
    fun saveText(expected: ConversationDraft,text: String,now: Long): ConversationDraft {
        requireCurrent(expected)
        if(expected.text==text) return expected
        return put(expected.copy(revision=Math.addExact(expected.revision,1),text=text,rich=expected.rich.copy(entities=persistentListOf()),updatedAt=now))
    }
    fun saveContent(expected: ConversationDraft,text: String,rich: MessageRichContent,now: Long): ConversationDraft {
        requireCurrent(expected);rich.validate(text)
        if(expected.text==text && expected.rich==rich) return expected
        return put(expected.copy(revision=Math.addExact(expected.revision,1),text=text,rich=rich,updatedAt=now))
    }
    fun add(room: RoomId,attachment: SendAttachment,now: Long): ConversationDraft {
        val current=read(room)
        current.attachments.firstOrNull { it.asset==attachment.asset || it.id==attachment.id }?.let { require(it==attachment);return current }
        requireCanSend(room)
        check(current.attachmentOrder.size<10) { "每条消息最多添加 10 个附件" }
        val asset=resources.original(attachment.asset,null)
        require(asset.purpose==ResourceUsage.Attachment(room) && asset.displayName==attachment.displayName && asset.contentType==attachment.contentType && asset.byteCount==attachment.byteCount)
        return put(current.copy(revision=Math.addExact(current.revision,1),attachments=current.attachments.add(attachment),attachmentOrder=current.attachmentOrder.add(attachment.id),updatedAt=now))
    }
    fun remove(expected: ConversationDraft,asset: String,now: Long): ConversationDraft {
        requireCurrent(expected);require(expected.attachments.any { it.asset==asset })
        resources.releaseSelection(asset)
        return put(expected.copy(revision=Math.addExact(expected.revision,1),attachments=expected.attachments.filterNot { it.asset==asset }.toPersistentList(),attachmentOrder=expected.attachmentOrder.remove(expected.attachments.first {it.asset==asset}.id),updatedAt=now))
    }
    fun reorder(expected: ConversationDraft,assets: PersistentList<String>,now: Long): ConversationDraft {
        requireCurrent(expected)
        val original=expected.attachments.associateBy { it.asset }
        require(assets.size==original.size && assets.toSet()==original.keys) { "附件顺序必须包含当前草稿的全部附件" }
        val next=assets.map { original.getValue(it) }.toPersistentList()
        if(next==expected.attachments) return expected
        val ids=next.map {it.id}.iterator();val uploads=expected.attachments.map {it.id}.toSet()
        val order=expected.attachmentOrder.map {if(it in uploads) ids.next() else it}.toPersistentList()
        return put(expected.copy(revision=Math.addExact(expected.revision,1),attachments=next,attachmentOrder=order,updatedAt=now))
    }
    fun addImport(expected: ConversationDraft,attachment: ConversationImportedAttachment,now: Long): ConversationDraft {
        val latest=read(expected.room)
        latest.imports.firstOrNull {it.id==attachment.id}?.let {require(it==attachment);return latest}
        requireCurrent(expected);check(!revoked(expected.room.value)) {"当前会话已不可访问"}
        requireCanSend(expected.room)
        check(currentSource(attachment.selection)) {"聊天附件来源已变化，请重新选择"}
        return put(expected.copy(revision=Math.addExact(expected.revision,1),imports=expected.imports.add(attachment),
            attachmentOrder=expected.attachmentOrder.add(attachment.id),updatedAt=now))
    }
    fun removeImport(expected: ConversationDraft,id: String,now: Long): ConversationDraft {
        requireCurrent(expected);require(expected.imports.any {it.id==id})
        return put(expected.copy(revision=Math.addExact(expected.revision,1),imports=expected.imports.filterNot {it.id==id}.toPersistentList(),
            attachmentOrder=expected.attachmentOrder.remove(id),updatedAt=now))
    }
    fun reorderResources(expected: ConversationDraft,ids: PersistentList<String>,now: Long): ConversationDraft {
        requireCurrent(expected);require(ids.size==expected.attachmentOrder.size && ids.toSet()==expected.attachmentOrder.toSet())
        if(ids==expected.attachmentOrder) return expected
        val uploads=expected.attachments.associateBy {it.id}
        return put(expected.copy(revision=Math.addExact(expected.revision,1),attachments=ids.mapNotNull {uploads[it]}.toPersistentList(),attachmentOrder=ids,updatedAt=now))
    }
    fun submit(expected: ConversationDraft,intent: SendIntent,now: Long): SendIntent {
        require(intent.room==expected.room && intent.text==expected.sendText && intent.attachments==expected.attachments && intent.rich==expected.rich &&
            intent.serverImports==expected.sendImports && intent.attachmentOrder==expected.attachmentOrder)
        val previous=db.rawQuery("SELECT intent FROM conversation_draft_submissions WHERE room=? AND revision=?",arrayOf(expected.room.value,expected.revision.toString())).use { if(it.moveToFirst()) it.getString(0) else null }
        if(previous!=null) { require(previous==intent.id);return sends.enqueue(intent,now) }
        requireCanSend(expected.room)
        requireCurrent(expected)
        check(expected.imports.all {currentSource(it.selection)}) {"聊天附件来源已变化，请移除后重新选择"}
        val saved=sends.enqueue(intent,now)
        put(ConversationDraft(expected.room,Math.addExact(expected.revision,1),updatedAt=now))
        db.execSQL("INSERT INTO conversation_draft_submissions VALUES (?,?,?)",arrayOf<Any>(expected.room.value,expected.revision,intent.id))
        db.execSQL("DELETE FROM conversation_draft_submissions WHERE rowid NOT IN(SELECT rowid FROM conversation_draft_submissions ORDER BY rowid DESC LIMIT 128)")
        return saved
    }
}
