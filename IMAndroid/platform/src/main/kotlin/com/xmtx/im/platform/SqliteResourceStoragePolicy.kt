package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.ResourceOriginalPolicy

internal class SqliteResourceStoragePolicy(private val db:SQLiteDatabase) {
    init { if (!db.isReadOnly) {db.execSQL("CREATE TABLE IF NOT EXISTS resource_storage_policy(id INTEGER PRIMARY KEY CHECK(id=1),original_bytes INTEGER NOT NULL,temporary_bytes INTEGER NOT NULL,free_bytes INTEGER NOT NULL,selections INTEGER NOT NULL,cache_bytes INTEGER NOT NULL,cache_entries INTEGER NOT NULL,retained_bytes INTEGER NOT NULL,retained_entries INTEGER NOT NULL)")} }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(resource_storage_policy)",null).use {r->buildSet {while(r.moveToNext()) add(r.getString(1))}}
        if("managed_bytes" !in columns) db.execSQL("ALTER TABLE resource_storage_policy ADD COLUMN managed_bytes INTEGER")
    } }
    // The existing retained_bytes preference becomes a warning threshold; byte retention is no longer a hard cap.
    fun load(defaults:ResourceOriginalPolicy):ResourceOriginalPolicy {
        val value=db.rawQuery("SELECT original_bytes,temporary_bytes,free_bytes,selections,cache_bytes,cache_entries,retained_bytes,retained_entries,managed_bytes FROM resource_storage_policy WHERE id=1",null).use {r->
            if(!r.moveToFirst()) null else ResourceOriginalPolicy(r.getLong(0),r.getLong(1),r.getLong(2),r.getInt(3),r.getLong(4),r.getInt(5),r.getLong(6),r.getInt(7),if(r.isNull(8)) null else r.getLong(8))
        }
        if(value==null && !db.isReadOnly) save(defaults)
        return value ?: defaults
    }
    fun save(value:ResourceOriginalPolicy) {
        db.execSQL("INSERT OR REPLACE INTO resource_storage_policy (id,original_bytes,temporary_bytes,free_bytes,selections,cache_bytes,cache_entries,retained_bytes,retained_entries,managed_bytes) VALUES(1,?,?,?,?,?,?,?,?,?)",arrayOf(value.maximumOriginalBytes,value.maximumTemporaryBytes,value.minimumFreeBytes,value.maximumSelections,value.maximumCacheBytes,value.maximumCacheEntries,value.retainedWarningBytes,value.maximumRetainedEntries,value.maximumManagedBytes))
    }
}
