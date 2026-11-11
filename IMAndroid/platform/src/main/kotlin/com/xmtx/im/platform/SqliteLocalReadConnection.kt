package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import java.io.File

internal object SqliteLocalReadConnection {
    @Suppress("DEPRECATION")
    fun open(file: File): SQLiteDatabase = SQLiteDatabase.openDatabase(file, SQLiteDatabase.OpenParams.Builder()
        .setOpenFlags(SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
        // One non-WAL pool connection, kept alive across statements in the savepoint below.
        .setIdleConnectionTimeout(Long.MAX_VALUE).build())

    /** API 31's public beginTransaction uses a write transaction even on a read-only handle.
     * SAVEPOINT gives a deferred SQLite snapshot without that framework transaction rewrite.
     * Call only under the store's serialized synchronous access, using the connection above.
     * RELEASE is also safe on failure: OPEN_READONLY makes all persistent writes impossible.
     */
    fun <T> snapshot(db: SQLiteDatabase, body: () -> T): T {
        check(db.isReadOnly)
        db.execSQL("SAVEPOINT im_local_read")
        try { return body() } finally { db.execSQL("RELEASE SAVEPOINT im_local_read") }
    }
}
