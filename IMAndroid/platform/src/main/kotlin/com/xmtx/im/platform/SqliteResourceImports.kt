package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.database.Cursor
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import java.util.UUID

/** The account writer commits immutable requests before any network work and never stores byte capabilities. */
internal class SqliteResourceImports(private val db: SQLiteDatabase,private val actor: UserId) {
    init { if (!db.isReadOnly) { db.execSQL("CREATE TABLE IF NOT EXISTS resource_imports(id TEXT PRIMARY KEY,operation TEXT NOT NULL UNIQUE,media TEXT NOT NULL UNIQUE,request TEXT NOT NULL CHECK(length(request)<=65536),status TEXT CHECK(length(status)<=65536),created INTEGER NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0,confirmed INTEGER NOT NULL DEFAULT 0,retained INTEGER NOT NULL DEFAULT 1,execution TEXT NOT NULL DEFAULT '{}' CHECK(length(execution)<=8192))") } }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(resource_imports)",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        if("business_bound" !in columns) db.execSQL("ALTER TABLE resource_imports ADD COLUMN business_bound INTEGER NOT NULL DEFAULT 0")
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_import_consumers(consumer TEXT PRIMARY KEY,import_id TEXT NOT NULL REFERENCES resource_imports(id))")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_import_consumer_job ON resource_import_consumers(import_id)")
    } }
    private val columns="id,operation,media,request,status,created,cancelled,confirmed,retained,execution,business_bound"
    private fun decode(rows:Cursor):ResourceImportWork {
        val request=ResourceImportRequest.decode(Json.parseToJsonElement(rows.getString(3)).jsonObject)
        require(request.operation==rows.getString(1) && request.targetMedia==rows.getString(2))
        val status=if(rows.isNull(4)) null else ResourceImportStatus.decode(Json.parseToJsonElement(rows.getString(4)).jsonObject).also {it.boundTo(request,actor)}
        return ResourceImportWork(rows.getString(0),request,rows.getLong(5),status,rows.getInt(6)==1,rows.getInt(7)==1,rows.getInt(8)==1,Json.decodeFromString(rows.getString(9)),rows.getInt(10)==1)
    }
    init { if (!db.isReadOnly) {db.execSQL("CREATE INDEX IF NOT EXISTS resource_import_created ON resource_imports(created,id)")} }
    fun all()=db.rawQuery("SELECT $columns FROM resource_imports ORDER BY rowid",null).use {rows->buildList {while(rows.moveToNext()) add(decode(rows))}.toPersistentList()}
    fun find(id:String)=db.rawQuery("SELECT $columns FROM resource_imports WHERE id=?",arrayOf(id)).use {if(it.moveToFirst()) decode(it) else null}
    private fun get(id:String)=find(id) ?: throw NoSuchElementException("导入任务不可用")
    private fun put(value: ResourceImportWork) { db.execSQL("UPDATE resource_imports SET status=?,cancelled=?,confirmed=?,retained=?,execution=?,business_bound=? WHERE id=?",arrayOf<Any?>(value.status?.payload()?.toString(),if(value.cancellationRequested) 1 else 0,if(value.cancellationResolved) 1 else 0,if(value.retained) 1 else 0,Json.encodeToString(value.execution),if(value.businessBound) 1 else 0,value.id)) }
    fun prepare(id: String,request: ResourceImportRequest,now: Long): ResourceImportWork {
        val value=ResourceImportWork(id,request,now)
        all().firstOrNull { it.id==id }?.let { require(it.request==request);return it }
        prune();val jobs=all()
        check(jobs.size<1024) { "导入记录过多，请先处理已完成的任务" }
        val uploads=db.rawQuery("SELECT COUNT(*) FROM resource_uploads WHERE stage NOT IN ('Ready','Cancelled','Rejected','Expired')",null).use { it.moveToFirst();it.getInt(0) }
        check(jobs.count { !it.terminal }+uploads<32) { "待处理资源任务过多" }
        db.execSQL("INSERT INTO resource_imports(id,operation,media,request,created) VALUES (?,?,?,?,?)",arrayOf<Any?>(id,request.operation,request.targetMedia,request.payload().toString(),now));return value
    }
    fun recover(owner: String) { require(UUID.fromString(owner).toString().uppercase()==owner)
        all().filter { it.execution.owner!=null && it.execution.owner!=owner }.forEach { put(it.copy(execution=it.execution.copy(owner=null,token=null,attention=it.execution.attention || it.execution.attempts>=5,issue=ResourceImportIssue.Unknown))) }
    }
    fun claim(id: String,owner: String,now: Long): ResourceImportClaim? {
        val work=get(id);val prior=work.execution
        if(work.terminal || prior.paused || prior.attention || prior.owner!=null || prior.attempts>=5 || maxOf(prior.retryAt,prior.serverRetryAt)>now) return null
        val deadline=prior.deadline ?: Math.addExact(now,60000)
        if(deadline<=now) { put(work.copy(execution=prior.copy(attention=true,issue=ResourceImportIssue.BudgetExhausted)));return null }
        val token=UUID.randomUUID().toString().uppercase()
        val next=work.copy(execution=prior.copy(owner=owner,token=token,attempts=prior.attempts+1,deadline=deadline,retryAt=maxOf(prior.serverRetryAt,Math.addExact(now,minOf(30000L,1000L shl prior.attempts)))))
        put(next);return ResourceImportClaim(next,owner,token)
    }
    private fun owned(claim: ResourceImportClaim): ResourceImportWork? {
        val current=get(claim.work.id);require(current.request==claim.work.request)
        return current.takeIf { it.execution.owner==claim.owner && it.execution.token==claim.token }
    }
    fun finish(claim: ResourceImportClaim,status: ResourceImportStatus,now: Long) {
        status.boundTo(claim.work.request,actor);val current=owned(claim) ?: return
        val old=current.status
        if(old?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed)) require(old==status)
        if(old?.state==ResourceImportState.Ready) require(status.state.terminal)
        val confirmed=current.cancellationResolved || current.cancellationRequested && status.state.terminal && (claim.work.cancellationRequested || status.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed))
        val polls=(current.execution.polls+1).coerceAtMost(60)
        val attention=!status.state.terminal && polls>=60
        val delay=when { polls<3->2000L;polls<6->5000L;polls<12->10000L;else->30000L }
        put(current.copy(status=status,cancellationResolved=confirmed,execution=current.execution.copy(owner=null,token=null,attempts=0,deadline=null,polls=polls,paused=if(status.state.terminal) false else current.execution.paused,
            retryAt=maxOf(current.execution.serverRetryAt,if(current.cancellationRequested && !confirmed) now else Math.addExact(now,delay)),attention=attention,issue=if(attention) ResourceImportIssue.PollingExhausted else null)))
    }
    fun fail(claim: ResourceImportClaim,issue: ResourceImportIssue,retryAt: Long?,serverRetryAt: Long,cancelled: Boolean) {
        val current=owned(claim) ?: return;val previous=current.execution
        require(serverRetryAt>=0 && (retryAt==null || retryAt>=0))
        val server=maxOf(previous.serverRetryAt,serverRetryAt)
        val changed=current.cancellationRequested!=claim.work.cancellationRequested
        put(current.copy(execution=previous.copy(owner=null,token=null,serverRetryAt=server,
            attention=if(cancelled || changed) previous.attention || previous.attempts>=5 else retryAt==null || previous.attempts>=5,
            retryAt=if(cancelled || changed) maxOf(previous.retryAt,server) else maxOf(retryAt ?: Long.MAX_VALUE,server),issue=issue)))
    }
    private fun consumers(id: String)=db.rawQuery("SELECT consumer FROM resource_import_consumers WHERE import_id=?",arrayOf(id)).use { rows -> buildList { while(rows.moveToNext()) add(rows.getString(0)) } }
    fun hasConsumer(id:String,consumer:ResourceImportConsumer)=consumer.key in consumers(id)
    fun hasConsumers(id:String)=consumers(id).isNotEmpty()
    fun bind(id: String,consumer: ResourceImportConsumer) {
        val work=get(id);require(!work.businessBound && !work.cancellationRequested && work.status?.state !in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed))
        val owners=consumers(id)
        val sharedGroup=consumer is GroupAvatarOriginalConsumer && owners.isNotEmpty() && owners.all {it.startsWith("groupAvatar/")}
        require(owners.isEmpty() && work.retained || sharedGroup)
        db.execSQL("INSERT INTO resource_import_consumers(consumer,import_id) VALUES (?,?)",arrayOf(consumer.key,id))
        put(work.copy(retained=false))
    }
    fun requireConsumer(id: String,consumer: ResourceImportConsumer) { require(consumer.key in consumers(id)) }
    fun releaseConsumer(id: String,consumer: ResourceImportConsumer,committed: Boolean=false) {
        val work=get(id);requireConsumer(id,consumer)
        if(committed) { require(work.status?.state==ResourceImportState.Ready && work.execution.owner==null && !work.cancellationRequested);put(work.copy(businessBound=true)) }
        db.execSQL("DELETE FROM resource_import_consumers WHERE consumer=? AND import_id=?",arrayOf(consumer.key,id))
    }
    fun cancel(id: String) {
        val work=get(id);require(!work.businessBound && consumers(id).isEmpty()) { "导入仍由业务修改持有或已完成绑定" };if(work.cancellationRequested || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed)) return
        put(work.copy(cancellationRequested=true,execution=work.execution.copy(paused=false,attention=false,attempts=0,polls=0,deadline=null,retryAt=work.execution.serverRetryAt,issue=null)))
    }
    fun control(id: String,paused: Boolean,retry: Boolean) {
        val work=get(id);if(work.terminal) return
        if(retry) { require(work.execution.owner==null);put(work.copy(execution=work.execution.copy(paused=paused,attention=false,attempts=0,polls=0,deadline=null,retryAt=work.execution.serverRetryAt,issue=null))) }
        else if(work.execution.paused!=paused) put(work.copy(execution=work.execution.copy(paused=paused)))
    }
    fun release(id: String) { val work=get(id);require(work.terminal && work.execution.owner==null && consumers(id).isEmpty());if(work.retained) put(work.copy(retained=false));prune() }
    private fun groupAvatarHistory(id: String)=db.rawQuery("SELECT 1 FROM group_avatar_intents WHERE import_id=? LIMIT 1",arrayOf(id)).use {it.moveToFirst()}
    private fun prune() { all().filter { it.terminal && !it.retained && it.execution.owner==null && consumers(it.id).isEmpty() && !groupAvatarHistory(it.id) }.dropLast(500).forEach { db.execSQL("DELETE FROM resource_imports WHERE id=?",arrayOf(it.id)) } }
}
