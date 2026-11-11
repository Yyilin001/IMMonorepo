package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.serialization.json.*

internal class SqliteDirectSendingCapabilities(private val db:SQLiteDatabase,private val revoked:(String)->Boolean) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS direct_sending_capabilities(room TEXT PRIMARY KEY,can_send INTEGER NOT NULL CHECK(can_send IN (0,1)),version INTEGER NOT NULL CHECK(version>0),time INTEGER NOT NULL CHECK(time>=0))")
        db.beginTransaction()
        try {
            db.rawQuery("SELECT payload FROM records WHERE kind='direct_sending_capability'",null).use {rows->while(rows.moveToNext()) {
                project(DirectSendingCapability.decode(Json.parseToJsonElement(rows.getBlob(0).toString(Charsets.UTF_8)).jsonObject))
            }}
            db.execSQL("DELETE FROM records WHERE kind='direct_sending_capability'")
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}
    } }
    private fun read(room:RoomId)=db.rawQuery("SELECT can_send,version,time FROM direct_sending_capabilities WHERE room=?",arrayOf(room.value)).use {
        if(it.moveToFirst()) DirectSendingCapability(room,it.getInt(0)==1,it.getLong(1),it.getLong(2)) else null
    }
    fun available(room:RoomId):DirectSendingCapability? {
        if(revoked(room.value)) return null
        if(db.rawQuery("SELECT kind FROM room_kinds WHERE room=?",arrayOf(room.value)).use {it.moveToFirst() && it.getString(0)==RoomKind.Group.name}) return null
        return read(room)
    }
    fun project(value:DirectSendingCapability) {
        if(revoked(value.room.value)) return
        val old=read(value.room)
        if(old!=null) {
            if(old.stateVersion>value.stateVersion) return
            if(old.stateVersion==value.stateVersion) {if(old!=value) throw ClientFailure.Protocol();return}
        }
        db.execSQL("INSERT OR REPLACE INTO direct_sending_capabilities VALUES (?,?,?,?)",arrayOf(value.room.value,if(value.canSend) 1 else 0,value.stateVersion,value.updatedAt))
    }
}
