package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.core.database.sqlite.transaction
import com.xmtx.im.client.LocalDatabaseIdentity
import com.xmtx.im.client.LocalStoreFailure

internal object SqliteDatabaseIdentity {
    /** Migrate an older trusted store once; never replace a malformed existing identity. */
    fun establish(db: SQLiteDatabase): LocalDatabaseIdentity = db.transaction {
        val exists = db.rawQuery("SELECT type FROM sqlite_master WHERE name='im_database_identity'", null).use {
            if (!it.moveToFirst()) false else {
                if (it.getString(0) != "table") throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable)
                true
            }
        }
        if (!exists) {
            db.execSQL("CREATE TABLE im_database_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),format INTEGER NOT NULL CHECK(format=1),identity TEXT NOT NULL)")
            db.execSQL("INSERT INTO im_database_identity VALUES(1,1,?)", arrayOf(LocalDatabaseIdentity.create().value))
        }
        read(db)
    }
    fun read(db: SQLiteDatabase): LocalDatabaseIdentity = try {
            require(db.rawQuery("SELECT type FROM sqlite_master WHERE name='im_database_identity'", null).use {
                it.moveToFirst() && it.getString(0) == "table"
            })
            db.rawQuery("SELECT singleton,format,identity FROM im_database_identity", null).use { rows ->
                require(rows.moveToFirst() && rows.getType(0) == Cursor.FIELD_TYPE_INTEGER && rows.getLong(0) == 1L &&
                    rows.getType(1) == Cursor.FIELD_TYPE_INTEGER && rows.getLong(1) == 1L && rows.getType(2) == Cursor.FIELD_TYPE_STRING)
                val identity = LocalDatabaseIdentity(rows.getString(2))
                require(!rows.moveToNext())
                identity
            }
        } catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.StoreUnavailable) }
}
