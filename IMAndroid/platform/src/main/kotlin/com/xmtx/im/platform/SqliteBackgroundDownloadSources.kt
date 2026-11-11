package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*

/** Durable raw-byte and future-publication capacity; all calls run in the account writer transaction. */
internal class SqliteBackgroundDownloadSources(private val db:SQLiteDatabase,private val downloads:SqliteResourceDownloads,private val files:SqliteResourceFiles) {
    init { if (!db.isReadOnly) {db.execSQL("""CREATE TABLE IF NOT EXISTS resource_background_download_sources(
        id TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(length(payload)<=8192),bytes INTEGER NOT NULL CHECK(bytes>0 AND bytes<=536870912),
        raw_budget INTEGER NOT NULL CHECK(raw_budget>=bytes),allocated INTEGER NOT NULL DEFAULT 0 CHECK(allocated>=0),publication TEXT,
        deleting INTEGER NOT NULL DEFAULT 0 CHECK(deleting IN (0,1)),cache_limit INTEGER NOT NULL,temporary_limit INTEGER NOT NULL,managed_limit INTEGER)""")} }
    fun sources():PersistentList<BackgroundDownloadSource> = db.rawQuery("SELECT id,payload,bytes,raw_budget,allocated,publication,deleting,cache_limit,temporary_limit,managed_limit FROM resource_background_download_sources ORDER BY id LIMIT 129",null).use {rows->
        buildList {while(rows.moveToNext()) {
            val mapping=ResourceBackgroundDownloadMapping.decode(Json.parseToJsonElement(rows.getString(1)).jsonObject)
            require(mapping.id==rows.getString(0) && mapping.authorization.expectedBytes==rows.getLong(2))
            add(BackgroundDownloadSource(mapping,rows.getLong(3),rows.getLong(4),rows.getString(5),rows.getInt(6)==1,rows.getLong(7),rows.getLong(8),if(rows.isNull(9)) null else rows.getLong(9)))
        }}.toPersistentList().also {require(it.size<=128)}
    }
    private fun active(mapping:ResourceBackgroundDownloadMapping,received:Boolean=false) {
        require(downloads.backgrounds().any {it.mapping==mapping && (!received || it.received)})
        val row=requireNotNull(downloads.snapshot(mapping.download));require(row.sourceAvailable && row.work.control==ResourceDownloadControl.Run && row.work.backgroundPending)
    }
    fun begin(mapping:ResourceBackgroundDownloadMapping,rawBudget:Long,policy:ResourceOriginalPolicy) {
        active(mapping);require(sources().size<128 && rawBudget in mapping.authorization.expectedBytes..mapping.authorization.expectedBytes+1024*1024)
        db.execSQL("INSERT INTO resource_background_download_sources(id,payload,bytes,raw_budget,cache_limit,temporary_limit,managed_limit) VALUES(?,?,?,?,?,?,?)",
            arrayOf<Any?>(mapping.id,mapping.payload().toString(),mapping.authorization.expectedBytes,rawBudget,policy.maximumCacheBytes,policy.maximumTemporaryBytes,policy.maximumManagedBytes))
        requireCapacity(policy)
    }
    fun requireActive(mapping:ResourceBackgroundDownloadMapping)=active(mapping)
    private fun requireCapacity(policy:ResourceOriginalPolicy) {
        val rows=files.files();val reserved=backgroundSourceReservedBytes(db)
        val temporary=rows.filter {it.state==ResourceFileState.Publishing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)}
        require(temporary<=policy.maximumTemporaryBytes) {"后台下载临时额度不足"}
        policy.maximumManagedBytes?.let {limit->require(rows.filter {it.state!=ResourceFileState.Missing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)}<=limit) {"托管文件总额度不足"}}
    }
    fun publication(mapping:ResourceBackgroundDownloadMapping,id:String,reuse:Boolean,allocated:Long,current:ResourceOriginalPolicy):ResourceLocalFile {
        active(mapping,true);val source=sources().first {it.mapping==mapping};require(!source.deleting && allocated>=0)
        val policy=source.admission(current)
        source.publication?.let {old->files.files().firstOrNull {it.id==old && it.state in setOf(ResourceFileState.Publishing,ResourceFileState.Published)}?.let {return it}}
        // Transfer the future-copy credit to the canonical file row atomically, without charging a third payload.
        db.execSQL("UPDATE resource_background_download_sources SET allocated=?,publication=? WHERE id=?",arrayOf<Any>(allocated,id,mapping.id))
        val record=if(reuse) files.files().first {it.id==id && it.state==ResourceFileState.Published && it.byteCount==mapping.authorization.expectedBytes && it.checksum==mapping.authorization.checksum}
            else files.beginDownload(id,mapping.authorization.expectedBytes,mapping.authorization.checksum,policy)
        requireCapacity(policy);return record
    }
    fun delete(mapping:ResourceBackgroundDownloadMapping,finished:Boolean) {
        val source=sources().firstOrNull {it.mapping.id==mapping.id} ?: return
        require(source.mapping==mapping && downloads.backgrounds().none {it.mapping.id==mapping.id}) {"后台下载尚未排空"}
        if(finished) {require(source.deleting);db.execSQL("DELETE FROM resource_background_download_sources WHERE id=?",arrayOf(mapping.id))}
        else db.execSQL("UPDATE resource_background_download_sources SET deleting=1 WHERE id=?",arrayOf(mapping.id))
    }
}
internal data class BackgroundDownloadSource(val mapping:ResourceBackgroundDownloadMapping,val rawBudget:Long,val allocated:Long,val publication:String?,
    val deleting:Boolean,val cacheLimit:Long,val temporaryLimit:Long,val managedLimit:Long?) {
    init {require(rawBudget>=mapping.authorization.expectedBytes && allocated>=0);publication?.let {require(java.util.UUID.fromString(it).toString().uppercase()==it)}}
    val reservedBytes get()=Math.addExact(maxOf(rawBudget,allocated),if(publication==null) mapping.authorization.expectedBytes else 0)
    fun admission(current:ResourceOriginalPolicy)=current.copy(maximumCacheBytes=maxOf(current.maximumCacheBytes,cacheLimit),maximumTemporaryBytes=maxOf(current.maximumTemporaryBytes,temporaryLimit),
        maximumManagedBytes=if(current.maximumManagedBytes==null || managedLimit==null) null else maxOf(requireNotNull(current.maximumManagedBytes),managedLimit))
}
