package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString

/** Called only under the store mutex and a single transaction; no OFFSET or history materialization. */
internal class SqliteConversationTimeline(private val db: SQLiteDatabase, private val actor: UserId,
    private val revoked: (String) -> Boolean, private val decode: (Cursor) -> Message,private val outbox: (RoomId)->PersistentList<Message>) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE INDEX IF NOT EXISTS messages_timeline ON messages(room,sequence,id)")
        db.execSQL("CREATE INDEX IF NOT EXISTS reaction_timeline ON reaction_versions(room,message)")
    } }

    fun sources(room: RoomId, viewer: UserId, ids: PersistentSet<MessageId>): PersistentMap<MessageId, Message> {
        require(ids.size <= 100)
        if (ids.isEmpty() || viewer != actor || revoked(room.value)) return persistentMapOf()
        return db.rawQuery("SELECT $COLUMNS FROM messages WHERE room=? AND id IN (${placeholders(ids.size)}) " +
            "AND withdrawn=0 AND revision>0 " +
            "AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=messages.id)",
            (listOf(room.value) + ids.map { it.value }).toTypedArray()).use { rows ->
            buildMap { while (rows.moveToNext()) { val message=decode(rows);put(message.id,message) } }.toPersistentMap()
        }
    }

    fun read(room: RoomId, viewer: UserId, selection: TimelineSelection, limit: Int): ConversationTimelineWindow {
        require(limit in 1..200)
        if (viewer != actor || revoked(room.value)) return ConversationTimelineWindow(available = false)
        val selected = when (selection) {
            TimelineSelection.Latest -> rows(room, null, "<", false, limit)
            is TimelineSelection.Before -> rows(room, selection.cursor, "<", false, limit)
            is TimelineSelection.Through -> rows(room, selection.cursor, "<=", false, limit)
            is TimelineSelection.After -> rows(room, selection.cursor, ">", true, limit)
        }
        return window(room, if (selection is TimelineSelection.After) selected else selected.reversed(),emptyLatest=selection==TimelineSelection.Latest)
    }

    fun locate(room: RoomId, viewer: UserId, message: MessageId, before: Int, after: Int): TimelineLocation {
        require(before >= 0 && after >= 0 && before < 200 && after < 200 && before + after + 1 <= 200)
        if (viewer != actor || revoked(room.value)) return TimelineLocation.Unavailable
        val target = db.rawQuery("SELECT $COLUMNS FROM messages WHERE room=? AND id=?", arrayOf(room.value, message.value)).use {
            if (it.moveToFirst()) decode(it) else null
        } ?: return if(outbox(room).any {it.id==message}) TimelineLocation.Found(read(room,viewer,TimelineSelection.Latest,before+after+1)) else TimelineLocation.Unavailable
        if (target.withdrawn || target.redacted) return TimelineLocation.Withdrawn
        val cursor = target.timelineCursor()
        val selected = rows(room, cursor, "<", false, before).reversed() + ConversationTimelineEntry.MessageEntry(target) + rows(room, cursor, ">", true, after)
        return TimelineLocation.Found(window(room, selected))
    }

    fun locateActivity(room:RoomId,viewer:UserId,source:String,before:Int,after:Int):TimelineLocation {
        require(before>=0 && after>=0 && before+after+1<=200)
        if(viewer!=actor || revoked(room.value)) return TimelineLocation.Unavailable
        val target=db.rawQuery("SELECT source,room,sequence,kind,time FROM timeline_activities WHERE room=? AND source=?",arrayOf(room.value,source)).use {
            if(it.moveToFirst()) SqliteTimelineActivities.decode(it) else null
        } ?: return TimelineLocation.Unavailable
        val cursor=target.cursor()
        return TimelineLocation.Found(window(room,rows(room,cursor,"<",false,before).reversed()+ConversationTimelineEntry.ActivityEntry(target)+rows(room,cursor,">",true,after)))
    }
    private fun rows(room: RoomId,cursor:TimelineCursor?,comparison:String,ascending:Boolean,limit:Int):List<ConversationTimelineEntry> {
        if(limit==0) return emptyList()
        val order=if(ascending) "ASC" else "DESC"
        fun query(activity:Boolean):List<ConversationTimelineEntry> {
            val table=if(activity) "timeline_activities" else "messages"
            val id=if(activity) "source" else "id"
            val kind=if(activity) 1 else 0
            val columns=if(activity) "source,room,sequence,kind,time" else COLUMNS
            val args=mutableListOf(room.value)
            val predicate=if(cursor==null) "" else {
                args+=cursor.sequence.toString();args+=cursor.message.value;args+=cursor.kind.ordinal.toString()
                " AND (sequence,$id,$kind) $comparison (?,?,CAST(? AS INTEGER))"
            }
            args+=limit.toString()
            return db.rawQuery("SELECT $columns FROM $table WHERE room=?$predicate ORDER BY sequence $order,$id $order LIMIT ?",args.toTypedArray()).use {rows->
                buildList {while(rows.moveToNext()) add(if(activity) ConversationTimelineEntry.ActivityEntry(SqliteTimelineActivities.decode(rows)) else ConversationTimelineEntry.MessageEntry(decode(rows)))}
            }
        }
        val comparator=compareBy<ConversationTimelineEntry,TimelineCursor>(timelineCursorOrder) {it.cursor}
        return (query(false)+query(true)).sortedWith(if(ascending) comparator else comparator.reversed()).take(limit)
    }

    private fun window(room: RoomId, entries: List<ConversationTimelineEntry>,emptyLatest: Boolean=false): ConversationTimelineWindow {
        val selected=entries.filterIsInstance<ConversationTimelineEntry.MessageEntry>().map {it.message}
        val activities=entries.filterIsInstance<ConversationTimelineEntry.ActivityEntry>().map {it.activity}.toPersistentList()
        val first = entries.firstOrNull()?.cursor; val last = entries.lastOrNull()?.cursor
        val older = first?.let {boundary(room,it,false)?.let {first}}
        val newer = last?.let {boundary(room,it,true)}
        val echoes = if(newer==null && (entries.isNotEmpty() || emptyLatest)) outbox(room) else persistentListOf()
        val references = (selected+echoes).mapNotNull {it.rich?.replyTo}.distinct()
        val replies = if (references.isEmpty()) persistentMapOf() else db.rawQuery(
            "SELECT $COLUMNS FROM messages WHERE room=? AND id IN (${placeholders(references.size)}) AND withdrawn=0 AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=messages.id)",
            (listOf(room.value) + references.map { it.value }).toTypedArray()).use { rows ->
            buildMap { while (rows.moveToNext()) { val message = decode(rows); put(message.id, message) } }.toPersistentMap()
        }
        if(selected.isEmpty()) return ConversationTimelineWindow(olderCursor=older,newerBoundary=newer,replySources=replies,outbox=echoes,latest=newer==null && (entries.isNotEmpty() || emptyLatest),activities=activities)
        val ids = selected.map { it.id.value }; val placeholders = placeholders(ids.size)
        val reactions = db.rawQuery("""
            SELECT r.message,r.reaction,COUNT(*),MAX(CASE WHEN r.actor=? THEN 1 ELSE 0 END)
            FROM reaction_versions r JOIN messages m ON m.id=r.message AND m.room=r.room
            WHERE r.room=? AND r.message IN ($placeholders) AND r.present=1 AND m.withdrawn=0
              AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=r.message)
            GROUP BY r.message,r.reaction ORDER BY r.message,r.reaction
        """.trimIndent(), (listOf(actor.value, room.value) + ids).toTypedArray()).use { rows ->
            buildList { while (rows.moveToNext()) add(MessageReactionSummary(room, MessageId(rows.getString(0)), rows.getString(1), rows.getInt(2), rows.getInt(3) != 0)) }.toPersistentList()
        }
        val pins = db.rawQuery("SELECT p.effect FROM group_pins p JOIN messages m ON m.id=p.message AND m.room=p.room WHERE p.room=? AND p.message IN ($placeholders) AND m.withdrawn=0",
            (listOf(room.value) + ids).toTypedArray()).use { rows ->
            buildSet { while (rows.moveToNext()) { val pin = Json.decodeFromString<GroupMetadataEffect.Pin>(rows.getString(0)); if (pin.pinned) add(pin.message) } }.toPersistentSet()
        }
        val checkpoint = db.rawQuery("SELECT c.sequence,s.head FROM room_cursors c LEFT JOIN read_room_state s ON s.room=c.room WHERE c.room=?", arrayOf(room.value)).use {
            if (it.moveToFirst()) RoomReadCheckpoint(room, it.getLong(0), if (it.isNull(1)) null else it.getLong(1)) else null
        }
        val direct = db.rawQuery("SELECT p.value FROM direct_read_projections p JOIN room_kinds k ON k.room=p.room AND k.kind='Direct' WHERE p.room=?", arrayOf(room.value)).use {
            if (it.moveToFirst()) Json.decodeFromString<DirectReadProjection>(it.getString(0)).takeIf { value -> value.visible && value.sequence > 0 } else null
        }
        return ConversationTimelineWindow(selected.toPersistentList(), older, newer, replies, reactions, pins, checkpoint, direct,outbox=echoes,activities=activities)
    }

    private fun boundary(room:RoomId,cursor:TimelineCursor,newer:Boolean):TimelineCursor? =
        rows(room,cursor,if(newer) ">" else "<",newer,1).firstOrNull()?.cursor

    private fun placeholders(count: Int) = List(count) { "?" }.joinToString(",")
    companion object {
        const val COLUMNS = "id,room,sender,text,time,withdrawn,revision,sequence,forwarded_message,forwarded_sender,(SELECT redacted FROM message_tombstones t WHERE t.id=messages.id),accepted_sequence,media,rich"
    }
}
