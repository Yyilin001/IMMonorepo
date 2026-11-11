package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.*

internal class SqliteTimelineActivities(private val db:SQLiteDatabase,private val revoked:(String)->Boolean) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS timeline_activities(source TEXT PRIMARY KEY,room TEXT NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>0),kind TEXT NOT NULL,time INTEGER NOT NULL CHECK(time>=0),UNIQUE(room,sequence))")
        db.execSQL("CREATE INDEX IF NOT EXISTS timeline_activity_order ON timeline_activities(room,sequence,source)")
        db.beginTransaction()
        try {
            db.rawQuery("SELECT event,payload FROM records WHERE kind='timeline_activity'",null).use {rows->while(rows.moveToNext()) {
                project(TimelineActivity.decode(rows.getString(0).substringBefore('/'),Json.parseToJsonElement(rows.getBlob(1).toString(Charsets.UTF_8)).jsonObject))
            }}
            db.execSQL("DELETE FROM records WHERE kind='timeline_activity'")
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}
    } }
    fun project(value:TimelineActivity) {
        if(revoked(value.room.value)) return
        val old=db.rawQuery("SELECT source,room,sequence,kind,time FROM timeline_activities WHERE source=?",arrayOf(value.sourceEvent)).use {if(it.moveToFirst()) decode(it) else null}
        if(old!=null) {if(old!=value) throw ClientFailure.Protocol();return}
        db.execSQL("INSERT INTO timeline_activities VALUES (?,?,?,?,?)",arrayOf(value.sourceEvent,value.room.value,value.sequence,value.kind.wire,value.createdAt))
    }
    companion object {
        fun decode(row:Cursor)=TimelineActivity(row.getString(0),RoomId(row.getString(1)),row.getLong(2),TimelineActivityKind.entries.single {it.wire==row.getString(3)},row.getLong(4))
    }
}
