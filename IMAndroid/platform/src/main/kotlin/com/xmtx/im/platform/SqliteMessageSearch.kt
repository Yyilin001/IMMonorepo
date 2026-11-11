package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.*
import java.util.UUID

/** Derived FTS4 index. Sync writes only durable invalidations; tokenization happens in bounded worker turns.
 * Primary rows, source stamps, indexed candidates and publication watermarks share a read transaction. */
internal class SqliteMessageSearch(private val db: SQLiteDatabase, private val actor: UserId,
    private val decode: (Cursor)->Message, private val generation: ()->Long) {
    private val instance=UUID.randomUUID().toString()
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS message_search_meta (id INTEGER PRIMARY KEY CHECK(id=1), generation INTEGER NOT NULL, ready INTEGER NOT NULL, bootstrap INTEGER NOT NULL, source_sequence INTEGER NOT NULL, publication INTEGER NOT NULL)")
        db.execSQL("INSERT OR IGNORE INTO message_search_meta(id,generation,ready,bootstrap,source_sequence,publication) VALUES (1,1,0,0,0,0)")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_search_sources (id TEXT PRIMARY KEY, stamp INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_search_jobs (id TEXT PRIMARY KEY)")
        db.execSQL("CREATE INDEX IF NOT EXISTS search_record_kind ON records(kind)")
        db.execSQL("CREATE TABLE IF NOT EXISTS message_search_documents (id TEXT UNIQUE NOT NULL, room TEXT NOT NULL, sender TEXT NOT NULL, sequence INTEGER NOT NULL, time INTEGER NOT NULL, stamp INTEGER NOT NULL, publication INTEGER NOT NULL, media INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX IF NOT EXISTS search_global_order ON message_search_documents(time DESC,id DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS search_room_order ON message_search_documents(room,sequence DESC,id DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS search_sender_order ON message_search_documents(sender,time DESC,id DESC)")
        db.execSQL("CREATE VIRTUAL TABLE IF NOT EXISTS message_search_fts USING fts4(tokens, tokenize=simple)")
        val columns=db.rawQuery("PRAGMA table_info(message_search_meta)",null).use {r->buildSet {while(r.moveToNext()) add(r.getString(1))}}
        if("format" !in columns) db.execSQL("ALTER TABLE message_search_meta ADD COLUMN format TEXT NOT NULL DEFAULT ''")
        if("source_cursor" !in columns) db.execSQL("ALTER TABLE message_search_meta ADD COLUMN source_cursor INTEGER NOT NULL DEFAULT 0")
        if("source_ready" !in columns) db.execSQL("ALTER TABLE message_search_meta ADD COLUMN source_ready INTEGER NOT NULL DEFAULT 0")
        val format="grapheme-nfkc-root-source-v2/${android.icu.util.VersionInfo.ICU_VERSION}"
        val old=db.rawQuery("SELECT format FROM message_search_meta WHERE id=1",null).use {it.moveToFirst();it.getString(0)}
        if(old!=format) {rebuild();db.execSQL("UPDATE message_search_meta SET format=? WHERE id=1",arrayOf(format))}

        for (event in listOf("INSERT","UPDATE")) db.execSQL("""
            CREATE TRIGGER IF NOT EXISTS message_search_${event.lowercase()} AFTER $event ON messages BEGIN
                UPDATE message_search_meta SET source_sequence=source_sequence+1 WHERE id=1;
                INSERT OR REPLACE INTO message_search_sources VALUES (new.id,(SELECT source_sequence FROM message_search_meta WHERE id=1));
                INSERT OR REPLACE INTO message_search_jobs VALUES (new.id);
            END
        """.trimIndent())
        db.execSQL("""
            CREATE TRIGGER IF NOT EXISTS message_search_delete AFTER DELETE ON messages BEGIN
                UPDATE message_search_meta SET source_sequence=source_sequence+1 WHERE id=1;
                DELETE FROM message_search_sources WHERE id=old.id;
                INSERT OR REPLACE INTO message_search_jobs VALUES (old.id);
            END
        """.trimIndent())
    } }
    private fun readableIndex(): Boolean = try {
        val compatible = db.rawQuery("SELECT format FROM message_search_meta WHERE id=1", null).use {
            it.moveToFirst() && it.getString(0) == "grapheme-nfkc-root-source-v2/${android.icu.util.VersionInfo.ICU_VERSION}"
        }
        compatible && db.rawQuery("SELECT tokens FROM message_search_fts LIMIT 0", null).use { it.moveToFirst(); true }
    } catch (_: android.database.sqlite.SQLiteException) { false }
    fun progress(): MessageSearchProgress = if (db.isReadOnly && !readableIndex()) MessageSearchProgress(false, 0, 0, 0)
    else db.rawQuery("SELECT ready,source_sequence,generation,(SELECT COUNT(*) FROM message_search_jobs) FROM message_search_meta WHERE id=1",null).use {
        check(it.moveToFirst());MessageSearchProgress(it.getInt(0)==1,it.getLong(3).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),it.getLong(1),it.getLong(2))
    }
    fun rebuild() {
        db.execSQL("DELETE FROM message_search_fts");db.execSQL("DELETE FROM message_search_documents");db.execSQL("DELETE FROM message_search_jobs")
        db.execSQL("UPDATE message_search_meta SET generation=generation+1,ready=0,bootstrap=0,publication=0,source_cursor=0,source_ready=0 WHERE id=1")
    }
    fun process(limit: Int): MessageSearchProgress {
        require(limit in 1..256)
        if(number("SELECT source_ready FROM message_search_meta WHERE id=1")==0L) {
            val after=number("SELECT source_cursor FROM message_search_meta WHERE id=1")
            val rows=db.rawQuery("SELECT rowid,payload FROM records WHERE kind='message' AND rowid>? ORDER BY rowid LIMIT ?",arrayOf(after.toString(),limit.toString())).use {
                buildList {while(it.moveToNext()) add(it.getLong(0) to it.getBlob(1))}
            }
            for((row,bytes) in rows) {
                recoverSource(bytes)
                db.execSQL("UPDATE message_search_meta SET source_cursor=? WHERE id=1",arrayOf(row))
            }
            if(rows.size==limit) return progress()
            db.execSQL("UPDATE message_search_meta SET source_ready=1 WHERE id=1")
        }
        if (!progress().ready) {
            val after=number("SELECT bootstrap FROM message_search_meta WHERE id=1")
            val rows=db.rawQuery("SELECT rowid,id FROM messages WHERE rowid>? ORDER BY rowid LIMIT ?",arrayOf(after.toString(),limit.toString())).use {
                buildList {while(it.moveToNext()) add(it.getLong(0) to it.getString(1))}
            }
            for ((row,id) in rows) {
                if (stamp(id)==null) {
                    db.execSQL("UPDATE message_search_meta SET source_sequence=source_sequence+1 WHERE id=1")
                    db.execSQL("INSERT INTO message_search_sources VALUES (?,(SELECT source_sequence FROM message_search_meta WHERE id=1))",arrayOf(id))
                }
                index(id);db.execSQL("DELETE FROM message_search_jobs WHERE id=?",arrayOf(id))
                db.execSQL("UPDATE message_search_meta SET bootstrap=? WHERE id=1",arrayOf(row))
            }
            if(rows.size<limit) db.execSQL("UPDATE message_search_meta SET ready=1 WHERE id=1")
        } else {
            val ids=db.rawQuery("SELECT id FROM message_search_jobs ORDER BY rowid LIMIT ?",arrayOf(limit.toString())).use {
                buildList {while(it.moveToNext()) add(it.getString(0))}
            }
            for(id in ids) {index(id);db.execSQL("DELETE FROM message_search_jobs WHERE id=?",arrayOf(id))}
        }
        return progress()
    }
    /** Older releases stored a presentation placeholder. Recover only the exact retained revision;
     * partial/expired evidence cannot manufacture a literal body. New projections write source_text directly. */
    private fun recoverSource(bytes: ByteArray) {
        val source=runCatching {
            val raw=Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
            val value=if(raw["event_type"]?.jsonPrimitive?.content=="message.edited")
                raw["replacement"]?.takeUnless {it is JsonNull}?.jsonObject?.get("state")?.jsonObject ?: raw else raw
            if(value["event_type"]?.jsonPrimitive?.content !in setOf("message.accepted","message.edited")) return
            val body=value.getValue("text").jsonPrimitive.takeIf {it.isString}?.content ?: return
            val id=MessageId(value.getValue("message_id").jsonPrimitive.content)
            val room=RoomId(value.getValue("room_id").jsonPrimitive.content)
            val revision=value.getValue("message_revision").jsonPrimitive.long
            arrayOf<Any>(body,id.value,room.value,revision,body.ifEmpty {"[附件]"})
        }.getOrNull() ?: return
        db.execSQL("UPDATE messages SET source_text=? WHERE id=? AND room=? AND revision=? AND text=? AND source_text IS NULL AND withdrawn=0",source)
    }
    private fun stamp(id: String): Long? = db.rawQuery("SELECT stamp FROM message_search_sources WHERE id=?",arrayOf(id)).use {if(it.moveToFirst()) it.getLong(0) else null}
    private fun number(sql: String) = db.compileStatement(sql).use {it.simpleQueryForLong()}
    private fun index(id: String) {
        db.execSQL("DELETE FROM message_search_fts WHERE rowid IN (SELECT rowid FROM message_search_documents WHERE id=?)",arrayOf(id))
        db.execSQL("DELETE FROM message_search_documents WHERE id=?",arrayOf(id))
        val message=db.rawQuery("SELECT ${SqliteConversationTimeline.COLUMNS},source_text FROM messages WHERE id=?",arrayOf(id)).use {
            if(it.moveToFirst()) decode(it).copy(text=if(!it.isNull(14)) it.getString(14) else it.getString(3).takeUnless {text->text=="[附件]"}.orEmpty()) else null
        } ?: return
        if(message.withdrawn || message.redacted || message.roomSequence<=0) return
        val stamp=stamp(id) ?: return
        val phrase=MessageSearchText.encode(message.text)
        val media=message.media?.presentations.orEmpty().fold(0) {flags,item -> flags or when(item.kind) {
            MessageMediaKind.Image,MessageMediaKind.AnimatedImage -> 1
            MessageMediaKind.Video -> 2
            MessageMediaKind.File -> 4
            MessageMediaKind.Audio -> 8
        }}
        db.execSQL("UPDATE message_search_meta SET publication=publication+1 WHERE id=1")
        db.execSQL("INSERT INTO message_search_documents VALUES (?,?,?,?,?,?,(SELECT publication FROM message_search_meta WHERE id=1),?)",
            arrayOf<Any>(id,message.roomId.value,message.sender.value,message.roomSequence,message.createdAt,stamp,media))
        val row=number("SELECT last_insert_rowid()")
        if(phrase.isNotEmpty()) db.execSQL("INSERT INTO message_search_fts(rowid,tokens) VALUES (?,?)",arrayOf<Any>(row,phrase))
    }
    fun search(viewer: UserId, request: MessageSearchRequest): MessageSearchPage {
        require(request.limit in 1..100)
        if(viewer!=actor) throw ClientFailure.SignedOut()
        val query=MessageSearchText(request.query)
        if(query.empty && request.content==MessageSearchContent.All && request.sender==null && request.scope !is MessageSearchScope.Sender) throw MessageSearchFailure.EmptyQuery()
        val progress=progress();if(!progress.ready) throw MessageSearchFailure.Building()
        val context=MessageSearchContext(instance,viewer,generation(),progress.generation,request.scope,request.content,request.sender,query.phrase)
        val cursor=request.cursor
        val publication=number("SELECT publication FROM message_search_meta WHERE id=1")
        if(cursor!=null && (cursor.context!=context || cursor.watermark !in 0..publication)) throw MessageSearchFailure.InvalidContinuation()
        val watermark=cursor?.watermark ?: publication
        val clauses=mutableListOf("d.publication<=?","d.stamp=s.stamp","m.withdrawn=0",
            "NOT EXISTS(SELECT 1 FROM memberships a WHERE a.room=d.room AND a.member=0)",
            "NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=d.id)")
        val args=mutableListOf(watermark.toString())
        var from="message_search_documents d JOIN message_search_sources s ON s.id=d.id JOIN messages m ON m.id=d.id"
        if(!query.empty) {from+=" JOIN message_search_fts ON message_search_fts.rowid=d.rowid";clauses+="message_search_fts MATCH ?";args+="\"${query.phrase}\""}
        when(val scope=request.scope) {
            MessageSearchScope.All -> Unit
            is MessageSearchScope.Room -> {clauses+="d.room=?";args+=scope.room.value}
            is MessageSearchScope.Sender -> {clauses+="d.sender=?";args+=scope.sender.value}
        }
        request.sender?.let {clauses+="d.sender=?";args+=it.value}
        when(request.content) {
            MessageSearchContent.All -> Unit
            MessageSearchContent.Media -> clauses+="d.media<>0"
            else -> {clauses+="(d.media & ?)<>0";args+=when(request.content) {MessageSearchContent.Image->1;MessageSearchContent.Video->2;MessageSearchContent.File->4;else->8}.toString()}
        }
        val order=if(request.scope is MessageSearchScope.Room) "d.sequence" else "d.time"
        if(cursor!=null) {clauses+="($order,d.id)<(?,?)";args+=cursor.order.toString();args+=cursor.message.value}
        args+=(request.limit+1).toString()
        val candidates=db.rawQuery("SELECT d.id,d.room,d.sender,d.sequence,d.time,m.revision,COALESCE(m.source_text,CASE WHEN m.text='[附件]' THEN '' ELSE m.text END) FROM $from WHERE ${clauses.joinToString(" AND ")} ORDER BY $order DESC,d.id DESC LIMIT ?",args.toTypedArray()).use {rows ->
            buildList {while(rows.moveToNext()) {
                val preview=query.preview(rows.getString(6)) ?: throw ClientFailure.Storage()
                add(MessageSearchHit(MessageId(rows.getString(0)),RoomId(rows.getString(1)),UserId(rows.getString(2)),rows.getLong(3),rows.getLong(4),rows.getLong(5),preview))
            }}
        }
        val hits=candidates.take(request.limit).toPersistentList()
        val next=if(candidates.size>request.limit) hits.last().let {MessageSearchCursor(context,watermark,if(request.scope is MessageSearchScope.Room) it.roomSequence else it.createdAt,it.message)} else null
        return MessageSearchPage(hits,next,progress.pending>0)
    }
}
