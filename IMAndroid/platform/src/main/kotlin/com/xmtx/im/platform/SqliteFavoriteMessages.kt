package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import java.util.UUID

/** Derived lookup updated in the same transaction as both personal authority streams. */
internal class SqliteFavoriteMessages(private val db: SQLiteDatabase,private val actor: UserId) {
    private val scope=UUID.randomUUID().toString()
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS favorite_sources (source TEXT NOT NULL,key TEXT NOT NULL,room TEXT NOT NULL,message TEXT NOT NULL,revision INTEGER NOT NULL,updated INTEGER NOT NULL,favorited INTEGER NOT NULL,PRIMARY KEY(source,key))")
        db.execSQL("CREATE INDEX IF NOT EXISTS favorite_order ON favorite_sources(favorited,updated DESC,room DESC,message DESC)")
        db.execSQL("CREATE INDEX IF NOT EXISTS favorite_authority ON favorite_sources(key,revision,source)")
    } }
    fun project(source: String,state: PersonalState) {
        val favorite=state.target as? PersonalTarget.Favorite ?: return
        db.execSQL("INSERT OR REPLACE INTO favorite_sources VALUES (?,?,?,?,?,?,?)",arrayOf<Any>(source,favorite.key,favorite.room.value,favorite.message.value,state.revision,state.updatedAt,if(favorite.favorited) 1 else 0))
    }
    fun clearProjections() {db.execSQL("DELETE FROM favorite_sources WHERE source='personal_projections'")}
    private val base="""
        FROM favorite_sources f JOIN messages m ON m.id=f.message AND m.room=f.room
        WHERE f.favorited=1 AND m.withdrawn=0 AND m.revision>0
          AND NOT EXISTS(SELECT 1 FROM favorite_sources other WHERE other.key=f.key AND
            (other.revision>f.revision OR (other.revision=f.revision AND other.source<f.source)))
          AND NOT EXISTS(SELECT 1 FROM memberships member WHERE member.room=f.room AND member.member=0)
          AND NOT EXISTS(SELECT 1 FROM message_tombstones t WHERE t.id=m.id)
    """.trimIndent()
    fun read(viewer: UserId,selection: FavoriteMessageSelection,limit: Int): FavoriteMessagePage {
        require(limit in 1..100)
        if(viewer!=actor) return FavoriteMessagePage()
        val cursor=when(selection) {FavoriteMessageSelection.Latest->null;is FavoriteMessageSelection.Before->selection.cursor;is FavoriteMessageSelection.After->selection.cursor}
        require(cursor==null || cursor.scope==scope) {"Favorite continuation belongs to another store"}
        val ascending=selection is FavoriteMessageSelection.After
        val comparison=if(ascending) ">" else "<";val order=if(ascending) "ASC" else "DESC"
        val predicate=if(cursor==null) "" else " AND (f.updated,f.room,f.message) $comparison (?,?,?)"
        val args=(cursor?.let {listOf(it.updatedAt.toString(),it.room.value,it.message.value)} ?: emptyList())+limit.toString()
        val rows=db.rawQuery("SELECT f.room,f.message,m.text,m.time,f.updated $base $predicate ORDER BY f.updated $order,f.room $order,f.message $order LIMIT ?",args.toTypedArray()).use {rows->
            buildList {while(rows.moveToNext()) add(FavoriteMessageItem(RoomId(rows.getString(0)),MessageId(rows.getString(1)),rows.getString(2),rows.getLong(3),rows.getLong(4)))}
        }
        val items=(if(ascending) rows.reversed() else rows).toPersistentList()
        fun boundary(item: FavoriteMessageItem,comparison: String): FavoriteMessageCursor? = db.rawQuery(
            "SELECT 1 $base AND (f.updated,f.room,f.message) $comparison (?,?,?) LIMIT 1",arrayOf(item.updatedAt.toString(),item.room.value,item.message.value)
        ).use {if(it.moveToFirst()) FavoriteMessageCursor(scope,item.updatedAt,item.room,item.message) else null}
        return FavoriteMessagePage(items,items.firstOrNull()?.let {boundary(it,">")},items.lastOrNull()?.let {boundary(it,"<")})
    }
}
