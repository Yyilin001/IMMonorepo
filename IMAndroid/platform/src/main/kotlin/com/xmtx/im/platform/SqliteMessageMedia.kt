package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.*

internal fun decodeMessageMedia(room: RoomId,value: JsonObject): MessageMedia=try {
    MessageMedia.decodeProjection(room,value)
} catch(_: Exception) { throw ClientFailure.Protocol() }
internal fun decodeStoredMessageMedia(room: String,value: String?): MessageMedia? = value?.let {
    decodeMessageMedia(RoomId(room),Json.parseToJsonElement(it).jsonObject)
}

/** Runs in the schema transaction. Unknown history stays NULL, never an inferred empty attachment set. */
internal fun migrateMessageMedia(db: SQLiteDatabase) {
    db.execSQL("ALTER TABLE messages ADD COLUMN media TEXT")
    data class Recovery(val room: RoomId,val revision: Long,val accepted: MutableMap<Long,MessageMedia> = mutableMapOf(),
        val edits: MutableSet<Long> = mutableSetOf(),val conflicts: MutableSet<Long> = mutableSetOf())
    val messages=db.rawQuery("SELECT id,room,revision FROM messages WHERE withdrawn=0",null).use { rows -> buildMap {
        while(rows.moveToNext()) put(MessageId(rows.getString(0)),Recovery(RoomId(rows.getString(1)),rows.getLong(2)))
    } }
    db.rawQuery("SELECT payload FROM records WHERE kind='message'",null).use { rows -> while(rows.moveToNext()) {
        val raw=runCatching { Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject }.getOrNull() ?: continue
        val id=runCatching { MessageId(raw.getValue("message_id").jsonPrimitive.content) }.getOrNull() ?: continue
        val recovery=messages[id] ?: continue
        if(raw["room_id"]?.jsonPrimitive?.content?.let { runCatching { RoomId(it) }.getOrNull() }!=recovery.room) continue
        val revision=raw["message_revision"]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: continue
        if(revision !in 1..recovery.revision) continue
        val type=raw["event_type"]?.jsonPrimitive?.content
        val envelope=raw["replacement"]?.takeUnless { it is JsonNull } as? JsonObject
        if(type=="message.edited" && envelope==null && raw["replacement"].let { it==null || it is JsonNull }) {
            if(raw["text"]?.jsonPrimitive?.takeIf { it.isString }?.content?.isNotEmpty()==true) recovery.edits.add(revision)
            continue
        }
        val value=when(type) {
            "message.accepted"->raw
            "message.edited"->envelope?.get("state") as? JsonObject
            else->null
        } ?: continue
        if(type=="message.edited" && (envelope?.get("schema_version")?.jsonPrimitive?.longOrNull!=1L ||
            (envelope["accepted_membership_revision"]?.jsonPrimitive?.longOrNull ?: 0)<=0)) continue
        val media=runCatching {
            require(value["event_type"]?.jsonPrimitive?.content=="message.accepted")
            if(type=="message.edited") require(value["media_ids"] is JsonArray && value["media_presentations"] is JsonArray)
            require(MessageId(value.getValue("message_id").jsonPrimitive.content)==id && RoomId(value.getValue("room_id").jsonPrimitive.content)==recovery.room)
            require(value.getValue("message_revision").jsonPrimitive.long==revision)
            decodeMessageMedia(recovery.room,value)
        }.getOrNull()
        if(media==null) { recovery.conflicts.add(revision);continue }
        val old=recovery.accepted.put(revision,media)
        if(old!=null && old!=media) recovery.conflicts.add(revision)
    } }
    for((id,recovery) in messages) {
        // A complete later replacement can establish facts again after an older gap.
        val base=recovery.accepted.keys.filter { it !in recovery.conflicts }.maxOrNull() ?: continue
        var version=base
        while(version<recovery.revision && version+1 in recovery.edits && version+1 !in recovery.conflicts) version++
        if(version==recovery.revision) db.execSQL("UPDATE messages SET media=? WHERE id=?",arrayOf(recovery.accepted.getValue(base).payload().toString(),id.value))
    }
    db.execSQL("UPDATE messages SET media=? WHERE withdrawn=1",arrayOf(MessageMedia.Empty.payload().toString()))
}
