package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.serialization.json.*

internal fun storedMessageRich(text: String,value: String?): MessageRichContent?=value?.let {
    MessageRichContent.decodeProjection(text,Json.parseToJsonElement(it).jsonObject)
}
/** Recover actual recorded content, never infer a missing revision or turn unknown facts into empty facts. */
internal fun migrateMessageRich(db: SQLiteDatabase) {
    db.execSQL("ALTER TABLE messages ADD COLUMN rich TEXT")
    data class Content(val text: String,val rich: MessageRichContent)
    data class Recovery(val room: RoomId,val revision: Long,val text: String,val accepted: MutableMap<Long,Content> = mutableMapOf(),
        val edits: MutableMap<Long,String> = mutableMapOf(),val conflicts: MutableSet<Long> = mutableSetOf())
    val messages=db.rawQuery("SELECT id,room,revision,text FROM messages WHERE withdrawn=0",null).use {rows->buildMap {
        while(rows.moveToNext()) put(MessageId(rows.getString(0)),Recovery(RoomId(rows.getString(1)),rows.getLong(2),rows.getString(3)))
    }}
    db.rawQuery("SELECT payload FROM records WHERE kind='message'",null).use {rows->while(rows.moveToNext()) {
        val raw=runCatching {Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject}.getOrNull() ?: continue
        val id=runCatching {MessageId(raw.getValue("message_id").jsonPrimitive.content)}.getOrNull() ?: continue
        val recovery=messages[id] ?: continue
        if(runCatching {RoomId(raw.getValue("room_id").jsonPrimitive.content)}.getOrNull()!=recovery.room) continue
        val revision=(raw["message_revision"] as? JsonPrimitive)?.takeUnless {it.isString}?.longOrNull ?: continue
        if(revision !in 1..recovery.revision) continue
        val type=(raw["event_type"] as? JsonPrimitive)?.content
        val envelope=raw["replacement"]?.takeUnless {it is JsonNull} as? JsonObject
        if(type=="message.edited" && envelope==null && raw["replacement"].let {it==null || it is JsonNull}) {
            val text=(raw["text"] as? JsonPrimitive)?.takeIf {it.isString}?.content?.takeIf {it.isNotEmpty()} ?: continue
            recovery.edits.put(revision,text)?.let {if(it!=text) recovery.conflicts.add(revision)};continue
        }
        val value=when(type) {"message.accepted"->raw;"message.edited"->envelope?.get("state") as? JsonObject;else->null} ?: continue
        val content=runCatching {
            if(envelope!=null) require(envelope["schema_version"]?.jsonPrimitive?.longOrNull==1L && (envelope["accepted_membership_revision"]?.jsonPrimitive?.longOrNull ?: 0)>0)
            require(value["event_type"]?.jsonPrimitive?.content=="message.accepted")
            require(MessageId(value.getValue("message_id").jsonPrimitive.content)==id && RoomId(value.getValue("room_id").jsonPrimitive.content)==recovery.room && value.getValue("message_revision").jsonPrimitive.long==revision)
            val text=value.getValue("text").jsonPrimitive.takeIf {it.isString}?.content ?: error("text")
            Content(text,MessageRichContent.decodeProjection(text,value,complete=envelope!=null))
        }.getOrNull()
        if(content==null) {recovery.conflicts.add(revision);continue}
        recovery.accepted.put(revision,content)?.let {if(it!=content) recovery.conflicts.add(revision)}
    }}
    for((id,r) in messages) {
        val base=r.accepted.keys.filter {it !in r.conflicts}.maxOrNull() ?: continue
        var version=base;var value=r.accepted.getValue(base)
        while(version<r.revision && version+1 in r.edits && version+1 !in r.conflicts) {
            version++;value=Content(r.edits.getValue(version),value.rich.copy(entities=persistentListOf()))
        }
        if(version==r.revision && value.text.ifEmpty {"[附件]"}==r.text) db.execSQL("UPDATE messages SET rich=? WHERE id=?",arrayOf(value.rich.payload().toString(),id.value))
    }
    db.execSQL("UPDATE messages SET rich=? WHERE withdrawn=1",arrayOf(MessageRichContent.Empty.payload().toString()))
}
