package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList

/** Invoked under the store's read transaction. Cached text/cursors alone never establish authority. */
internal class SqliteLocalProjection(private val db: SQLiteDatabase, private val actor: UserId) {
    private val allowed = """
        NOT EXISTS (SELECT 1 FROM memberships m WHERE m.room=r.id AND m.member=0)
        AND (
            EXISTS (SELECT 1 FROM records p WHERE p.room=r.id AND p.kind IN ('room','membership'))
            OR EXISTS (SELECT 1 FROM direct_profile_bindings d WHERE d.room=r.id AND d.revision>
                COALESCE((SELECT f.revision FROM presentation_floors f WHERE f.kind='security' AND f.room='' AND f.user=d.user),0))
        )
    """.trimIndent()
    fun allows(room: RoomId) = db.rawQuery("SELECT 1 FROM rooms r WHERE r.id=? AND $allowed", arrayOf(room.value)).use { it.moveToFirst() }

    fun conversations(before: LocalConversationCursor?, limit: Int): LocalConversationPage {
        require(limit in 1..100)
        // Fetch only the selected bounded page, never materialize appSnapshot or its operation journals.
        val args = mutableListOf<String>()
        val boundary = if (before == null) "" else {
            args += before.updatedAt.toString(); args += before.updatedAt.toString(); args += before.room.value
            "WHERE updated < CAST(? AS INTEGER) OR (updated = CAST(? AS INTEGER) AND id > ?)"
        }
        args += (limit + 1).toString()
        val entries = db.rawQuery("""
            WITH permitted AS (
                SELECT r.id,
                    CASE WHEN EXISTS(SELECT 1 FROM records p WHERE p.room=r.id AND p.kind IN ('room','membership')) THEN r.title ELSE '会话' END AS title,
                    (SELECT m.id FROM messages m WHERE m.room=r.id ORDER BY m.sequence DESC,m.id DESC LIMIT 1) AS latest,
                    CASE WHEN EXISTS(SELECT 1 FROM records p WHERE p.room=r.id AND p.kind IN ('room','membership')) THEN NULL
                         ELSE (SELECT d.user FROM direct_profile_bindings d WHERE d.room=r.id) END AS peer
                FROM rooms r WHERE $allowed
            ), previews AS (
                SELECT p.id,p.title,p.peer,COALESCE(m.time,0) AS updated,
                    CASE WHEN m.withdrawn=1 THEN '消息已撤回' WHEN m.id IS NULL THEN ''
                         WHEN m.text='' THEN '附件（联网后查看）' ELSE m.text END AS preview
                FROM permitted p LEFT JOIN messages m ON m.room=p.id AND m.id=p.latest
            )
            SELECT id,title,updated,preview,peer FROM previews $boundary ORDER BY updated DESC,id ASC LIMIT ?
        """.trimIndent(), args.toTypedArray()).use { rows ->
            buildList { while (rows.moveToNext()) add(LocalConversation(RoomId(rows.getString(0)), rows.getString(1), rows.getString(3), rows.getLong(2)) to
                if (rows.isNull(4)) null else ProfileKey(UserId(rows.getString(4)), ProfileContext.DirectConversation)) }
        }
        val selected = entries.take(limit)
        val names = SqliteLocalProfileDisplays(db, actor).load(selected.mapNotNull { it.second }.toPersistentList())
        val page = selected.map { (value, key) -> key?.let { names.value(it)?.name }?.let { value.copy(title = it) } ?: value }.toPersistentList()
        return LocalConversationPage(page, page.lastOrNull()?.takeIf { entries.size > limit }?.let { LocalConversationCursor(it.updatedAt, it.room) })
    }
    fun messages(room: RoomId, before: TimelineCursor?, limit: Int): LocalMessagePage {
        require(limit in 1..100)
        if (!allows(room)) return LocalMessagePage(room, kotlinx.collections.immutable.persistentListOf(), null, false)
        val args = mutableListOf(room.value)
        val boundary = if (before == null) "" else {
            require(before.kind == TimelineItemKind.Message)
            args += before.sequence.toString(); args += before.message.value
            "AND (sequence,id) < (CAST(? AS INTEGER),?)"
        }
        args += (limit + 1).toString()
        val entries = db.rawQuery("SELECT id,sender,text,time,withdrawn,sequence FROM messages WHERE room=? $boundary ORDER BY sequence DESC,id DESC LIMIT ?", args.toTypedArray()).use { rows ->
            buildList { while (rows.moveToNext()) {
                val withdrawn = rows.getInt(4) != 0; val body = rows.getString(2)
                val value = LocalTextMessage(MessageId(rows.getString(0)), UserId(rows.getString(1)),
                    if (withdrawn) "消息已撤回" else body.ifEmpty { "附件（联网后查看）" }, rows.getLong(3), withdrawn, !withdrawn && body.isEmpty())
                add(value to TimelineCursor(rows.getLong(5), value.id))
            } }
        }
        val page = entries.take(limit)
        // Authors use the exact room context even in a direct conversation; remarks require that scope.
        fun key(user: UserId) = ProfileKey(user, ProfileContext.Room(room))
        val names = SqliteLocalProfileDisplays(db, actor).load(page.map { key(it.first.sender) }.distinct().toPersistentList())
        return LocalMessagePage(room, page.asReversed().map { it.first.copy(senderName = if (it.first.sender == actor) "你" else names.value(key(it.first.sender))?.name) }.toPersistentList(),
            page.lastOrNull()?.second?.takeIf { entries.size > limit }, true)
    }
}
