package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import java.util.UUID

internal class ResourceRetentionCapacityExceeded:IllegalStateException("保留项目数量已达上限")

internal class SqliteResourceRetention(private val db:SQLiteDatabase,private val catalog:SqliteResourceCatalog,private val files:SqliteResourceFiles) {
    data class CleanupSelection(val files:PersistentSet<String>,val resources:Int,val unavailable:Int,val absent:Int)
    fun cleanupSelection(resources:PersistentList<ResourceKey>,checkActive:()->Unit):CleanupSelection {
        require(resources.size in 1..100)
        val unique=resources.toPersistentSet();val selected=persistentSetOf<String>().builder()
        var unavailable=0;var absent=0
        for(resource in unique) {
            checkActive()
            if(catalog.visibleDescriptor(resource)==null) {unavailable++;continue}
            original(resource)
            // Do not reuse the 128-row detail page: every known rendition/version
            // can refer to distinct bytes. Only published payloads belong here.
            db.rawQuery("SELECT DISTINCT f.id FROM resource_variants v JOIN resource_files f ON f.checksum=v.checksum AND f.bytes=v.bytes WHERE v.resource=? AND f.state='Published'",arrayOf(resource.payload().toString())).use {rows->
                var found=false
                while(rows.moveToNext()) {checkActive();found=true;selected.add(rows.getString(0))}
                if(!found) absent++
            }
        }
        return CleanupSelection(selected.build(),unique.size,unavailable,absent)
    }
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_retention_plans(id TEXT PRIMARY KEY,created INTEGER NOT NULL,expires INTEGER NOT NULL,count INTEGER NOT NULL,more INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_retention_plan_items(plan TEXT NOT NULL,key TEXT NOT NULL,intent TEXT NOT NULL,PRIMARY KEY(plan,key))")
    } }
    fun plan(now:Long,checkActive:()->Unit):ResourceUnavailableRetentionPlan {
        checkActive()
        require(now in 0..Long.MAX_VALUE-60_000)
        db.execSQL("DELETE FROM resource_retention_plan_items WHERE plan IN (SELECT id FROM resource_retention_plans WHERE expires<=?)",arrayOf(now))
        db.execSQL("DELETE FROM resource_retention_plans WHERE expires<=?",arrayOf(now))
        check(db.compileStatement("SELECT COUNT(*) FROM resource_retention_plans").use {it.simpleQueryForLong()}<64) {"请稍后重新检查"}
        // Retention admission caps this index at 4096. Stream it without materializing filenames
        // or an unbounded collection; at most 101 unavailable intent identities are selected.
        val selected=mutableListOf<Pair<String,String>>()
        db.rawQuery("SELECT r.key,r.intent,v.descriptor FROM resource_retention r JOIN resource_variants v ON v.key=r.key ORDER BY r.time,r.key",null).use {rows->
            while(selected.size<101 && rows.moveToNext()) {
                checkActive()
                if(catalog.visibleDescriptor(decode(rows.getString(2)).key.resource)==null) selected.add(rows.getString(0) to rows.getString(1))
            }
        }
        val plan=ResourceUnavailableRetentionPlan(UUID.randomUUID().toString().uppercase(),minOf(100,selected.size),selected.size>100,now+60_000)
        db.execSQL("INSERT INTO resource_retention_plans VALUES (?,?,?,?,?)",arrayOf(plan.id,now,plan.expiresAt,plan.count,if(plan.hasMore) 1 else 0))
        for((key,intent) in selected.take(100)) db.execSQL("INSERT INTO resource_retention_plan_items VALUES (?,?,?)",arrayOf(plan.id,key,intent))
        checkActive();return plan
    }
    fun release(plan:ResourceUnavailableRetentionPlan,now:Long,checkActive:()->Unit):ResourceUnavailableRetentionResult {
        checkActive()
        db.rawQuery("SELECT created,expires,count,more FROM resource_retention_plans WHERE id=?",arrayOf(plan.id)).use {row->
            check(row.moveToFirst()) {"预览不属于当前账号或已失效"}
            check(now>=row.getLong(0) && now<row.getLong(1) && plan.expiresAt==row.getLong(1) && plan.count==row.getInt(2) && plan.hasMore==(row.getInt(3)==1)) {"预览已失效，请重新检查"}
        }
        var released=0
        db.rawQuery("SELECT p.key,p.intent,v.descriptor FROM resource_retention_plan_items p JOIN resource_variants v ON v.key=p.key WHERE p.plan=? ORDER BY p.key LIMIT 100",arrayOf(plan.id)).use {rows->
            while(rows.moveToNext()) {
                checkActive()
                if(catalog.visibleDescriptor(decode(rows.getString(2)).key.resource)!=null) continue
                db.execSQL("DELETE FROM resource_retention WHERE key=? AND intent=?",arrayOf(rows.getString(0),rows.getString(1)))
                released+=db.compileStatement("SELECT changes()").use {it.simpleQueryForLong().toInt()}
            }
        }
        checkActive();return ResourceUnavailableRetentionResult(released,plan.count-released)
    }
    fun observe(read:MessageResourceRead,target:MediaDownloadTarget) {
        target.requireValid();check(catalog.currentRead(read)) {"资源来源已变化"}
        val descriptor=target.preview ?: ResourceVariantDescriptor(ResourceVariantKey(read.descriptor.key),requireNotNull(read.descriptor.checksum),read.descriptor.byteCount)
        require(descriptor.key.resource==read.descriptor.key && descriptor.checksum==target.plan.checksum && descriptor.byteCount==target.plan.expectedBytes)
        index(descriptor)
    }
    private fun index(value:ResourceVariantDescriptor) {
        val key=value.key.payload().toString()
        val old=db.rawQuery("SELECT descriptor FROM resource_variants WHERE key=?",arrayOf(key)).use {if(it.moveToFirst()) decode(it.getString(0)) else null}
        if(old!=null) {require(old==value) {"资源版本内容冲突"};return}
        val derived=value.key.rendition as? ResourceRendition.Derived
        db.execSQL("INSERT INTO resource_variants(key,resource,descriptor,checksum,bytes,sort_kind,sort_id,sort_version) VALUES (?,?,?,?,?,?,?,?)",arrayOf(key,value.key.resource.payload().toString(),value.payload().toString(),value.checksum.value,value.byteCount,if(derived==null) 0 else 1,derived?.id ?: "",derived?.version ?: 0L))
    }
    private fun original(resource:ResourceKey) {
        val value=catalog.visibleDescriptor(resource) ?: return
        if(value.state==ResourceState.Ready) index(ResourceVariantDescriptor(ResourceVariantKey(resource),requireNotNull(value.checksum),value.byteCount))
    }
    fun variants(resource:ResourceKey):PersistentList<ResourceVariantSnapshot> {
        if(catalog.visibleDescriptor(resource)==null) return persistentListOf()
        original(resource)
        return db.rawQuery("SELECT v.descriptor,EXISTS(SELECT 1 FROM resource_retention r WHERE r.key=v.key),EXISTS(SELECT 1 FROM resource_files f WHERE f.checksum=v.checksum AND f.bytes=v.bytes AND f.state='Published') FROM resource_variants v WHERE v.resource=? ORDER BY v.sort_kind,v.sort_id,v.sort_version DESC,v.key LIMIT 128",arrayOf(resource.payload().toString())).use {rows->buildList {
            while(rows.moveToNext()) add(ResourceVariantSnapshot(decode(rows.getString(0)),rows.getInt(1)==1,rows.getInt(2)==1))
        }.toPersistentList()}
    }
    fun variant(key:ResourceVariantKey):ResourceVariantSnapshot? {
        if(catalog.visibleDescriptor(key.resource)==null) return null
        original(key.resource)
        return db.rawQuery("SELECT v.descriptor,EXISTS(SELECT 1 FROM resource_retention r WHERE r.key=v.key),EXISTS(SELECT 1 FROM resource_files f WHERE f.checksum=v.checksum AND f.bytes=v.bytes AND f.state='Published') FROM resource_variants v WHERE v.key=?",arrayOf(key.payload().toString())).use {row->
            if(row.moveToFirst()) ResourceVariantSnapshot(decode(row.getString(0)),row.getInt(1)==1,row.getInt(2)==1) else null
        }
    }
    fun setVisibleOriginal(resource:ResourceKey,retained:Boolean,policy:ResourceOriginalPolicy):ResourceRetentionBatchOutcome {
        val key=ResourceVariantKey(resource);val current=variant(key) ?: return ResourceRetentionBatchOutcome.Unavailable
        if(current.retained==retained) return ResourceRetentionBatchOutcome.Unchanged
        set(key,retained,policy);return ResourceRetentionBatchOutcome.Changed
    }
    fun set(key:ResourceVariantKey,retained:Boolean,policy:ResourceOriginalPolicy) {
        val encoded=key.payload().toString()
        if(!retained) {db.execSQL("DELETE FROM resource_retention WHERE key=?",arrayOf(encoded));return}
        check(catalog.visibleDescriptor(key.resource)!=null) {"资源来源已不可访问"}
        original(key.resource)
        val value=db.rawQuery("SELECT descriptor FROM resource_variants WHERE key=?",arrayOf(encoded)).use {check(it.moveToFirst()) {"资源版本尚未确认"};decode(it.getString(0))}
        if(db.rawQuery("SELECT 1 FROM resource_retention WHERE key=?",arrayOf(encoded)).use {it.moveToFirst()}) return
        if(db.compileStatement("SELECT COUNT(*) FROM resource_retention").use {it.simpleQueryForLong()}>=4096) throw ResourceRetentionCapacityExceeded()
        db.execSQL("INSERT INTO resource_retention VALUES (?,?,?,?,?)",arrayOf(encoded,value.checksum.value,value.byteCount,UUID.randomUUID().toString().uppercase(),System.currentTimeMillis()))
        files.requireRetainedCapacity(policy) // The owning transaction rolls back the intent on quota failure.
    }
    private fun decode(value:String)=ResourceVariantDescriptor.decode(Json.parseToJsonElement(value).jsonObject)
}
