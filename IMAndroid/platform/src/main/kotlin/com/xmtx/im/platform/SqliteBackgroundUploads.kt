package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.util.UUID
import kotlin.random.Random

/** Runs exclusively inside the account store's serialized SQLite writer transaction. */
internal class SqliteBackgroundUploads(private val db:SQLiteDatabase,private val resources:SqliteResourceFiles) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_background_session(singleton INTEGER PRIMARY KEY CHECK(singleton=1),id TEXT NOT NULL UNIQUE)")
        db.execSQL("""CREATE TABLE IF NOT EXISTS resource_background_uploads(
            id TEXT PRIMARY KEY,session TEXT NOT NULL,task TEXT NOT NULL,batch TEXT NOT NULL,job TEXT NOT NULL,payload TEXT NOT NULL,
            created INTEGER NOT NULL,completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0,1)),
            verified INTEGER NOT NULL DEFAULT 0 CHECK(verified IN (0,1)),finalize INTEGER NOT NULL DEFAULT 0 CHECK(finalize IN (0,1)),
            retry_floor INTEGER NOT NULL DEFAULT 0 CHECK(retry_floor>=0),UNIQUE(session,task))""")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_background_active ON resource_background_uploads(completed,created,id)")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_background_batch ON resource_background_uploads(batch,completed)")
        db.execSQL("""CREATE TABLE IF NOT EXISTS resource_background_sources(
            id TEXT PRIMARY KEY,payload TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>0 AND bytes<=268435456),
            allocated INTEGER NOT NULL CHECK(allocated>=0),state TEXT NOT NULL CHECK(state IN ('Preparing','Ready','Deleting')),
            checksum TEXT CHECK(length(checksum)=64),CHECK(state<>'Ready' OR checksum IS NOT NULL))""")
    } }
    fun session():String {
        db.rawQuery("SELECT id FROM resource_background_session WHERE singleton=1",null).use {if(it.moveToFirst()) return it.getString(0).also(::requireId)}
        return UUID.randomUUID().toString().uppercase().also {db.execSQL("INSERT INTO resource_background_session(singleton,id) VALUES(1,?)",arrayOf(it))}
    }
    private fun mappings(where:String,args:Array<String>?=null)=db.rawQuery("SELECT id,session,task,batch,job,payload FROM resource_background_uploads WHERE $where ORDER BY created,id LIMIT 64",args).use {rows->
        buildList {while(rows.moveToNext()) {
            val value=ResourceBackgroundUploadMapping.decode(Json.parseToJsonElement(rows.getString(5)).jsonObject)
            require(value.id==rows.getString(0) && value.systemSession==rows.getString(1) && value.task==rows.getString(2) && value.batch==rows.getString(3) && value.upload==rows.getString(4))
            add(value)
        }}.toPersistentList()
    }
    fun active()=mappings("completed=0").also {require(it.size<=16 && it.all {row->row.systemSession==session()})}
    fun install(claim:ResourceUploadClaim,tasks:PersistentList<ResourceBackgroundUploadRegistration>,now:Long):PersistentList<ResourceBackgroundUploadMapping> {
        require(now>=0 && tasks.size in 1..16 && tasks.map {it.id}.distinct().size==tasks.size && tasks.map {it.task}.distinct().size==tasks.size)
        val current=resources.owned(claim);val execution=current.execution
        require(!current.terminal && !current.cancellationRequested && !current.sourceReleased && !execution.userPaused && !execution.attention && !execution.backgroundPending)
        require(claim.work.execution.next==ResourceUploadAction.Upload && claim.work.session==current.session)
        val session=requireNotNull(current.session);tasks.forEach {it.target.requireValid(session,current.request)}
        val plans=tasks.map {it.target.plan}
        require(plans.map {it.backgroundUpload!!.id}.distinct().size==plans.size && plans.map {it.part}.distinct().size==plans.size)
        require(plans.size==1 || plans.all {it.mode==ResourceTransferMode.PartPut})
        val ranges=plans.mapNotNull {it.range}.sortedBy {it.lower};require(ranges.zipWithNext().all {(a,b)->a.upper<b.lower})
        require(count("completed=0")+tasks.size<=16)
        val system=session();val batch=tasks.first().id
        val mappings=tasks.map {registration->val plan=registration.target.plan
            ResourceBackgroundUploadMapping(registration.id,system,registration.task,batch,current.id,current.asset,claim.owner,
                resourceBackgroundRequestDigest(current.request),requireNotNull(plan.backgroundUpload),plan.range,plan.expectedBytes,resourceBackgroundOriginDigest(plan.url),now)
        }.toPersistentList()
        mappings.forEach {value->db.execSQL("INSERT INTO resource_background_uploads(id,session,task,batch,job,payload,created) VALUES(?,?,?,?,?,?,?)",
            arrayOf<Any>(value.id,value.systemSession,value.task,value.batch,value.upload,value.payload().toString(),value.createdAt))}
        resources.putExecution(current.id,execution.copy(owner=null,token=null,backgroundPending=true,next=ResourceUploadAction.Status,deadline=null))
        return mappings
    }
    fun complete(mapping:ResourceBackgroundUploadMapping,result:ResourceBackgroundUploadResult?,now:Long):Boolean {
        require(now>=0)
        val saved=mappings("id=? AND completed=0",arrayOf(mapping.id)).singleOrNull() ?: return false
        if(saved!=mapping || saved.systemSession!=session() || result!=null && (result.mapping!=saved.id || result.task!=saved.task)) return false
        val work=requireNotNull(resources.upload(saved.upload));val prior=work.execution
        require(prior.backgroundPending && prior.owner==null && !work.terminal && !work.sourceReleased)
        require(work.asset==saved.asset && resourceBackgroundRequestDigest(work.request)==saved.requestDigest)
        val uploadSession=requireNotNull(work.session)
        require(uploadSession.locator.session==saved.authorization.session && uploadSession.generation==saved.authorization.generation && uploadSession.media==saved.authorization.media)
        val same=result!=null && result.originDigest==saved.originDigest
        val success=same && result!!.error==null && result.status in 200..299 && result.sentBytes==saved.expectedBytes
        val finalize=saved.authorization.scope is ResourceBackgroundUploadScope.Whole && same && result!!.error==null && (success || result.status==409)
        val floor=if(same) result!!.retryNotBefore ?: 0 else 0
        db.execSQL("UPDATE resource_background_uploads SET completed=1,verified=?,finalize=?,retry_floor=? WHERE id=?",arrayOf<Any>(if(success || finalize) 1 else 0,if(finalize) 1 else 0,floor,saved.id))
        if(count("batch=? AND completed=0",arrayOf(saved.batch))==0L) {
            val outcome=db.rawQuery("SELECT MIN(verified),MAX(finalize),MAX(retry_floor) FROM resource_background_uploads WHERE batch=?",arrayOf(saved.batch)).use {
                check(it.moveToFirst());Triple(it.getInt(0)==1,it.getInt(1)==1,it.getLong(2))
            }
            val paused=prior.userPaused && !work.cancellationRequested
            val failed=!outcome.first && !paused && !work.cancellationRequested
            val attempts=if(failed) minOf(5,prior.backgroundAttempts+1) else if(outcome.first) 0 else prior.backgroundAttempts
            val attention=failed && attempts>=5
            val server=maxOf(prior.serverRetryAt,outcome.third)
            val base=maxOf(now,server)
            val delay=if(failed) (minOf(30_000L,1000L shl attempts)*(0.5+Random.nextDouble()*0.5)).toLong() else 0
            val retry=if(delay>Long.MAX_VALUE-base) Long.MAX_VALUE else base+delay
            resources.putExecution(work.id,prior.copy(backgroundPending=false,backgroundAttempts=attempts,owner=null,token=null,attempts=0,deadline=null,
                next=if(work.cancellationRequested) ResourceUploadAction.Cancel else if(!paused && outcome.second) ResourceUploadAction.Finalize else ResourceUploadAction.Status,
                attention=attention,error=if(failed) ResourceUploadError.BackgroundOutcomeUnknown else null,serverRetryAt=server,retryAt=retry))
            if(failed) db.execSQL("UPDATE resource_uploads SET stage='Paused' WHERE id=?",arrayOf(work.id))
        }
        // Completed siblings stay until the whole batch drains; then retain a bounded late-callback tombstone window.
        db.execSQL("""DELETE FROM resource_background_uploads WHERE completed=1
            AND NOT EXISTS(SELECT 1 FROM resource_background_uploads AS pending WHERE pending.batch=resource_background_uploads.batch AND pending.completed=0)
            AND id NOT IN(SELECT id FROM resource_background_uploads ORDER BY created DESC,id DESC LIMIT 128)""")
        return true
    }
    fun sources():PersistentList<BackgroundUploadSource> = db.rawQuery("SELECT id,payload,bytes,allocated,state,checksum FROM resource_background_sources ORDER BY id",null).use {rows->
        buildList {while(rows.moveToNext()) {
            val mapping=ResourceBackgroundUploadMapping.decode(Json.parseToJsonElement(rows.getString(1)).jsonObject)
            require(mapping.id==rows.getString(0) && mapping.expectedBytes==rows.getLong(2))
            add(BackgroundUploadSource(mapping,rows.getLong(3),BackgroundSourceState.valueOf(rows.getString(4)),if(rows.isNull(5)) null else ResourceChecksum(rows.getString(5))))
        }}.toPersistentList()
    }
    fun requireSourceActive(mapping:ResourceBackgroundUploadMapping) {
        require(active().any {it==mapping}) {"后台上传映射已失效"}
        val work=requireNotNull(resources.upload(mapping.upload))
        require(!work.cancellationRequested && !work.execution.userPaused && !work.sourceReleased)
    }
    fun beginSource(mapping:ResourceBackgroundUploadMapping,policy:ResourceOriginalPolicy) {
        requireSourceActive(mapping);require(sources().size<128)
        val bytes=Math.multiplyExact(mapping.expectedBytes,2);val reserved=backgroundSourceReservedBytes(db)
        val records=resources.files()
        val temporary=records.filter {it.state==ResourceFileState.Publishing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)}
        require(temporary<=policy.maximumTemporaryBytes && bytes<=policy.maximumTemporaryBytes-temporary) {"后台传输临时额度不足"}
        policy.maximumManagedBytes?.let {maximum->
            val used=records.filter {it.state!=ResourceFileState.Missing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)}
            require(used<=maximum && bytes<=maximum-used) {"托管文件总额度不足"}
        }
        db.execSQL("INSERT INTO resource_background_sources(id,payload,bytes,allocated,state) VALUES(?,?,?,0,'Preparing')",arrayOf<Any>(mapping.id,mapping.payload().toString(),mapping.expectedBytes))
    }
    fun finishSource(mapping:ResourceBackgroundUploadMapping,checksum:ResourceChecksum,allocated:Long,policy:ResourceOriginalPolicy) {
        val record=sources().first {it.mapping==mapping};require(record.state==BackgroundSourceState.Preparing)
        require(allocated in 0..Long.MAX_VALUE/8)
        val replacement=record.copy(state=BackgroundSourceState.Ready,checksum=checksum,allocatedBytes=allocated)
        val extra=replacement.reservedBytes-record.reservedBytes
        val records=resources.files();val reserved=backgroundSourceReservedBytes(db)
        val temporary=records.filter {it.state==ResourceFileState.Publishing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)}
        require(temporary<=policy.maximumTemporaryBytes && extra<=policy.maximumTemporaryBytes-temporary)
        policy.maximumManagedBytes?.let {maximum->val used=records.filter {it.state!=ResourceFileState.Missing}.fold(reserved) {sum,row->Math.addExact(sum,row.chargedBytes)};require(used<=maximum && extra<=maximum-used)}
        db.execSQL("UPDATE resource_background_sources SET state='Ready',checksum=?,allocated=? WHERE id=?",arrayOf<Any>(checksum.value,allocated,mapping.id))
    }
    fun deleteSource(mapping:ResourceBackgroundUploadMapping,finished:Boolean,recoverPreparing:Boolean=false) {
        val record=sources().firstOrNull {it.mapping.id==mapping.id} ?: return
        require(record.mapping==mapping)
        // Only unpublished preparation can be recovered without proving the task drained.
        require(if(finished) record.state==BackgroundSourceState.Deleting else if(recoverPreparing) record.state==BackgroundSourceState.Preparing else active().none {it.id==mapping.id})
        if(finished) {require(record.state==BackgroundSourceState.Deleting);db.execSQL("DELETE FROM resource_background_sources WHERE id=?",arrayOf(mapping.id))}
        else db.execSQL("UPDATE resource_background_sources SET state='Deleting' WHERE id=?",arrayOf(mapping.id))
    }
    private fun count(where:String,args:Array<String>?=null)=android.database.DatabaseUtils.longForQuery(db,"SELECT COUNT(*) FROM resource_background_uploads WHERE $where",args)
    private fun requireId(value:String) {require(UUID.fromString(value).toString().uppercase()==value)}
}

internal enum class BackgroundSourceState { Preparing, Ready, Deleting }
internal data class BackgroundUploadSource(val mapping:ResourceBackgroundUploadMapping,val allocatedBytes:Long,val state:BackgroundSourceState,val checksum:ResourceChecksum?) {
    init {require(allocatedBytes in 0..Long.MAX_VALUE/8 && (state!=BackgroundSourceState.Ready || checksum!=null))}
    val reservedBytes get()=Math.addExact(maxOf(mapping.expectedBytes,allocatedBytes),mapping.expectedBytes)
}
internal fun backgroundSourceReservedBytes(db:SQLiteDatabase):Long=Math.addExact(
    android.database.DatabaseUtils.longForQuery(db,"SELECT COALESCE(SUM(MAX(bytes,allocated)+bytes),0) FROM resource_background_sources",null),
    android.database.DatabaseUtils.longForQuery(db,"SELECT COALESCE(SUM(MAX(raw_budget,allocated)+CASE WHEN publication IS NULL THEN bytes ELSE 0 END),0) FROM resource_background_download_sources",null))
