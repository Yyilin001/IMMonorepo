package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.LocalStoreFailure

/** Minimum current projection contract. Never creates missing columns or performs a migration. */
internal object SqliteLocalReadSchema {
    fun verify(db: SQLiteDatabase) {
        try {
            for ((table, columns) in listOf(
                "cursor" to "generation,sequence,token,receipt,receipt_sequence",
                "messages" to "id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,media,rich",
                "account_room_heads" to "room,sequence,membership,blocked",
                "resource_files" to "id,bytes,checksum,state,allocated,kind,last_used",
                "resource_uploads" to "id,asset,request,session,stage,cancelled,released,execution,created",
                "resource_imports" to "id,operation,media,request,status,created,cancelled,confirmed,retained,execution,business_bound",
                "resource_downloads" to "id,descriptor,room,message,created,phase,control,requested,attempts,owner,claim,issue,retry,server_retry,finished,automatic,background_pending",
            )) db.rawQuery("SELECT $columns FROM $table LIMIT 0", null).use { it.moveToFirst() }
        } catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable) }
    }
}
