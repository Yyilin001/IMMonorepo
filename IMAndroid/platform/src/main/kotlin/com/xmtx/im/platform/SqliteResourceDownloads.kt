package com.xmtx.im.platform

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import java.util.UUID

/** Every mutation is inside the account SQLite writer transaction. No transfer capability is persisted. */
internal class SqliteResourceDownloads(private val db:SQLiteDatabase,private val catalog:SqliteResourceCatalog,private val files:SqliteResourceFiles) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_downloads(id TEXT PRIMARY KEY,descriptor TEXT NOT NULL CHECK(length(descriptor)<=8192),room TEXT NOT NULL,message TEXT NOT NULL,created INTEGER NOT NULL,phase TEXT NOT NULL,control TEXT NOT NULL,requested INTEGER NOT NULL,attempts INTEGER NOT NULL CHECK(attempts BETWEEN 0 AND 5),owner TEXT,claim TEXT,issue TEXT,retry INTEGER NOT NULL,server_retry INTEGER NOT NULL,finished INTEGER,CHECK((owner IS NULL)=(claim IS NULL)))")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_download_schedule ON resource_downloads(phase,control,requested,retry,created,id)")
    } }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(resource_downloads)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("automatic" !in columns) db.execSQL("ALTER TABLE resource_downloads ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0 CHECK(automatic IN (0,1))")
        if("background_pending" !in columns) db.execSQL("ALTER TABLE resource_downloads ADD COLUMN background_pending INTEGER NOT NULL DEFAULT 0 CHECK(background_pending IN (0,1))")
        if("media" !in columns) db.execSQL("ALTER TABLE resource_downloads ADD COLUMN media TEXT")
        if("bytes" !in columns) db.execSQL("ALTER TABLE resource_downloads ADD COLUMN bytes INTEGER")
        if("checksum" !in columns) db.execSQL("ALTER TABLE resource_downloads ADD COLUMN checksum TEXT")
        while(true) {
            val rows=db.rawQuery("SELECT id,descriptor FROM resource_downloads WHERE media IS NULL LIMIT 100",null).use {cursor->buildList {while(cursor.moveToNext()) add(cursor.getString(0) to ResourceDescriptor.decode(Json.parseToJsonElement(cursor.getString(1)).jsonObject))}}
            if(rows.isEmpty()) break
            rows.forEach {(id,value)->db.execSQL("UPDATE resource_downloads SET media=?,bytes=?,checksum=? WHERE id=?",arrayOf(value.key.media,value.byteCount,value.checksum?.value,id))}
        }
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_download_identity ON resource_downloads(checksum,bytes)")
        db.execSQL("CREATE INDEX IF NOT EXISTS resource_download_media ON resource_downloads(media)")
    } }
    init { if (!db.isReadOnly) {db.execSQL("CREATE INDEX IF NOT EXISTS resource_download_created ON resource_downloads(created,id)")} }
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS resource_download_session(singleton INTEGER PRIMARY KEY CHECK(singleton=1),id TEXT NOT NULL UNIQUE)")
        db.execSQL("""CREATE TABLE IF NOT EXISTS resource_background_downloads(
            id TEXT PRIMARY KEY,session TEXT NOT NULL,task TEXT NOT NULL UNIQUE,job TEXT NOT NULL,payload TEXT NOT NULL CHECK(length(payload)<=8192),
            created INTEGER NOT NULL,received INTEGER NOT NULL DEFAULT 0 CHECK(received IN (0,1)),
            completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0,1)))""")
        db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS resource_background_download_job ON resource_background_downloads(job) WHERE completed=0")
    } }
    init { if (!db.isReadOnly) {db.execSQL("CREATE TABLE IF NOT EXISTS resource_download_network(singleton INTEGER PRIMARY KEY CHECK(singleton=1),cellular INTEGER NOT NULL CHECK(cellular IN (0,1)),constrained INTEGER NOT NULL CHECK(constrained IN (0,1)))")} }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(resource_download_network)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("automatic_kinds" !in columns) db.execSQL("ALTER TABLE resource_download_network ADD COLUMN automatic_kinds INTEGER NOT NULL DEFAULT 0 CHECK(automatic_kinds BETWEEN 0 AND 15)")
        if("automatic_bytes" !in columns) db.execSQL("ALTER TABLE resource_download_network ADD COLUMN automatic_bytes INTEGER NOT NULL DEFAULT 10485760 CHECK(automatic_bytes BETWEEN 1 AND 536870912)")
    } }
    private val automaticKinds=listOf(ResourceCategory.Image,ResourceCategory.Video,ResourceCategory.Audio,ResourceCategory.File)
    fun networkPreferences()=db.rawQuery("SELECT cellular,constrained,automatic_kinds,automatic_bytes FROM resource_download_network WHERE singleton=1",null).use {row->
        if(row.moveToFirst()) ResourceDownloadNetworkPreferences(row.getInt(0)==1,row.getInt(1)==1,
            ResourceAutomaticDownloadPolicy(automaticKinds.filterIndexed {index,_->row.getInt(2) and (1 shl index)!=0}.toPersistentSet(),row.getLong(3))) else ResourceDownloadNetworkPreferences()
    }
    fun networkPreferences(value:ResourceDownloadNetworkPreferences) {
        val mask=automaticKinds.foldIndexed(0) {index,mask,kind->if(kind in value.automaticDownloads.categories) mask or (1 shl index) else mask}
        db.execSQL("INSERT INTO resource_download_network(singleton,cellular,constrained,automatic_kinds,automatic_bytes) VALUES(1,?,?,?,?) ON CONFLICT(singleton) DO UPDATE SET cellular=excluded.cellular,constrained=excluded.constrained,automatic_kinds=excluded.automatic_kinds,automatic_bytes=excluded.automatic_bytes",
            arrayOf(if(value.allowsCellular) 1 else 0,if(value.allowsConstrained) 1 else 0,mask,value.automaticDownloads.maximumByteCount))
    }
    private val columns="id,descriptor,room,message,created,phase,control,requested,attempts,owner,claim,issue,retry,server_retry,finished,automatic,background_pending"
    private fun decode(row:Cursor)=ResourceDownloadWork(row.getString(0),ResourceDescriptor.decode(Json.parseToJsonElement(row.getString(1)).jsonObject),MediaMessageLocation(RoomId(row.getString(2)),MessageId(row.getString(3))),row.getLong(4),
        ResourceDownloadPhase.valueOf(row.getString(5)),ResourceDownloadControl.valueOf(row.getString(6)),row.getInt(7)==1,row.getInt(8),row.getString(9),row.getString(10),row.getString(11)?.let(ResourceDownloadIssue::valueOf),row.getLong(12),row.getLong(13),if(row.isNull(14)) null else row.getLong(14),row.getInt(15)==1,row.getInt(16)==1)
    private fun work(id:String)=db.rawQuery("SELECT $columns FROM resource_downloads WHERE id=?",arrayOf(id)).use {if(it.moveToFirst()) decode(it) else null}
    private fun all()=db.rawQuery("SELECT $columns FROM resource_downloads ORDER BY created,id",null).use {rows->buildList {while(rows.moveToNext()) add(decode(rows))}}
    private fun read(work:ResourceDownloadWork):MessageResourceRead? {
        val descriptor=catalog.visibleDescriptor(work.descriptor.key) ?: return null
        if(descriptor.state!=ResourceState.Ready || descriptor.byteCount!=work.descriptor.byteCount || descriptor.checksum!=work.descriptor.checksum) return null
        return try {catalog.selectRead(work.descriptor.key,work.message)} catch(_:ResourceCatalogConflict) {null}
    }
    fun snapshot(id:String)=work(id)?.let {ResourceDownloadSnapshot(it,read(it)!=null)}
    fun snapshots()=all().map {ResourceDownloadSnapshot(it,read(it)!=null)}.toPersistentList()
    private fun write(value:ResourceDownloadWork) {
        db.execSQL("UPDATE resource_downloads SET phase=?,control=?,requested=?,attempts=?,owner=?,claim=?,issue=?,retry=?,server_retry=?,finished=?,automatic=?,background_pending=? WHERE id=?",
            arrayOf(value.phase.name,value.control.name,if(value.requested) 1 else 0,value.attempts,value.owner,value.claim,value.issue?.name,value.retryAt,value.serverRetryAt,value.finishedAt,if(value.automatic) 1 else 0,if(value.backgroundPending) 1 else 0,value.id))
    }
    private fun prune(now:Long) {
        db.execSQL("DELETE FROM resource_downloads WHERE id IN (SELECT id FROM resource_downloads WHERE finished IS NOT NULL AND (finished<? OR id NOT IN (SELECT id FROM resource_downloads WHERE finished IS NOT NULL ORDER BY finished DESC,id DESC LIMIT 500)) ORDER BY finished,id LIMIT 100)",arrayOf((now-30L*24*60*60*1000).coerceAtLeast(0)))
    }
    fun enqueue(key:ResourceKey,source:MessageResourceSource,now:Long):ResourceDownloadWork {
        require(now>=0 && key.home==ResourceHome.Room(source.room))
        val evidence=catalog.selectRead(key,MediaMessageLocation(source.room,source.message))
        check(evidence.source.ordinal==source.ordinal) {"资源来源已变化"}
        val descriptor=evidence.descriptor;require(descriptor.byteCount in 1..512L*1024*1024)
        val active=all().filterNot {it.terminal}
        val prior=active.firstOrNull {it.descriptor.key==key || it.descriptor.checksum==descriptor.checksum && it.descriptor.byteCount==descriptor.byteCount}
        if(prior!=null) {
            check(prior.control==ResourceDownloadControl.Run) {"下载已暂停或正在取消，请在下载任务中处理"}
            // No new source, attempts, retry floor or permission can be installed by repeated clicks.
            require(prior.descriptor.checksum==descriptor.checksum && prior.descriptor.byteCount==descriptor.byteCount)
            return prior.copy(automatic=false).also {if(prior.automatic) write(it)}
        }
        check(active.size<16) {"下载任务已达上限"}
        val value=ResourceDownloadWork(UUID.randomUUID().toString().uppercase(),descriptor,MediaMessageLocation(source.room,source.message),now)
        insert(value)
        prune(now);return value
    }
    private fun insert(value:ResourceDownloadWork) {
        val descriptor=value.descriptor
        db.execSQL("INSERT INTO resource_downloads(id,descriptor,room,message,created,phase,control,requested,attempts,owner,claim,issue,retry,server_retry,finished,automatic,media,bytes,checksum) VALUES(?,?,?,?,?,'Pending','Run',1,0,NULL,NULL,NULL,0,0,NULL,?,?,?,?)",
            arrayOf(value.id,descriptor.payload().toString(),value.message.room.value,value.message.message.value,value.createdAt,if(value.automatic) 1 else 0,descriptor.key.media,descriptor.byteCount,descriptor.checksum?.value))
    }
    fun prepareAutomatic(now:Long,networkAllowed:Boolean) {
        require(now>=0)
        val policy=networkPreferences().automaticDownloads
        val active=all().filterNot {it.terminal}
        // Policy updates never resume user-paused/cancelled tasks or reset their attempt/server floors.
        for(value in active.filter {it.automatic && it.owner==null && !it.backgroundPending && it.control==ResourceDownloadControl.Run}) {
            val allowed=policy.allows(value.descriptor.contentType,value.descriptor.byteCount)
            if(!allowed && value.requested) write(value.copy(requested=false,issue=ResourceDownloadIssue.Policy))
            else if(allowed && networkAllowed && !value.requested && value.issue==ResourceDownloadIssue.Policy && value.attempts<5 && read(value)!=null)
                write(value.copy(requested=true,issue=null))
        }
        if(active.size>=12 || policy.categories.isEmpty()) return
        for(evidence in catalog.automaticCandidates(policy,minOf(2,12-active.size))) {
            // Recheck identity after each insert: this candidate page may contain equivalent bytes.
            val descriptor=evidence.descriptor
            val existing=db.rawQuery("SELECT 1 FROM resource_downloads WHERE media=? OR (checksum=? AND bytes=?) LIMIT 1",arrayOf(descriptor.key.media,descriptor.checksum!!.value,descriptor.byteCount.toString())).use {it.moveToFirst()}
            if(existing) continue
            val value=ResourceDownloadWork(UUID.randomUUID().toString().uppercase(),descriptor,MediaMessageLocation(evidence.source.room,evidence.source.message),now,automatic=true)
            insert(value);catalog.markAutomaticAdmitted(descriptor.key)
        }
    }
    fun control(id:String,control:ResourceDownloadControl,now:Long) {
        val value=work(id) ?: error("下载任务已不可用");check(!value.terminal);require(now>=0)
        when(control) {
            ResourceDownloadControl.Run->{
                check(value.owner==null && !value.backgroundPending && value.control!=ResourceDownloadControl.Cancel && (value.control==ResourceDownloadControl.Pause || !value.requested) && read(value)!=null) {"当前不能继续下载"}
                write(value.copy(control=control,requested=true,attempts=0,issue=null,retryAt=value.serverRetryAt,automatic=false))
            }
            ResourceDownloadControl.Pause->{
                check(value.control==ResourceDownloadControl.Run && (value.requested || value.owner!=null) && read(value)!=null) {"当前不能暂停下载"}
                write(value.copy(control=control,requested=false,issue=null))
            }
            ResourceDownloadControl.Cancel->{
                if(value.control==control) return
                val drained=value.owner==null && !value.backgroundPending
                write(value.copy(control=control,requested=false,phase=if(drained) ResourceDownloadPhase.Stopped else value.phase,finishedAt=if(drained) maxOf(now,value.createdAt) else null,issue=null))
                prune(now)
            }
        }
    }
    fun recover(owner:String,now:Long) {
        require(UUID.fromString(owner).toString().uppercase()==owner && now>=0)
        for(value in all().filter {it.owner!=null && it.owner!=owner}) {
            val cancelled=value.control==ResourceDownloadControl.Cancel
            write(value.copy(owner=null,claim=null,phase=if(cancelled) ResourceDownloadPhase.Stopped else ResourceDownloadPhase.Pending,
                requested=!cancelled && value.control==ResourceDownloadControl.Run && value.requested && value.attempts<5,
                issue=if(value.control==ResourceDownloadControl.Pause || cancelled) null else ResourceDownloadIssue.Interrupted,
                finishedAt=if(cancelled) maxOf(now,value.createdAt) else null))
        }
        prune(now)
    }
    fun claim(id:String,owner:String,now:Long):ResourceDownloadClaim? {
        require(UUID.fromString(owner).toString().uppercase()==owner && now>=0)
        val value=work(id) ?: return null
        if(value.phase!=ResourceDownloadPhase.Pending || value.backgroundPending || value.control!=ResourceDownloadControl.Run || !value.requested || value.attempts>=5 || maxOf(value.retryAt,value.serverRetryAt)>now) return null
        if(value.automatic && !networkPreferences().automaticDownloads.allows(value.descriptor.contentType,value.descriptor.byteCount)) {
            write(value.copy(requested=false,issue=ResourceDownloadIssue.Policy));return null
        }
        if(read(value)==null) {write(value.copy(requested=false,issue=ResourceDownloadIssue.Unavailable));return null}
        val next=value.copy(phase=ResourceDownloadPhase.Running,attempts=value.attempts+1,owner=owner,claim=UUID.randomUUID().toString().uppercase(),issue=null)
        write(next);return ResourceDownloadClaim(next)
    }
    private fun owned(claim:ResourceDownloadClaim)=work(claim.work.id)?.takeIf {it.owner==claim.work.owner && it.claim==claim.work.claim && !it.terminal}
    fun complete(claim:ResourceDownloadClaim,read:MessageResourceRead,now:Long) {
        val value=owned(claim) ?: return
        if(value.control!=ResourceDownloadControl.Run) return
        if(read.descriptor.key!=value.descriptor.key || read.descriptor.checksum!=value.descriptor.checksum || read.descriptor.byteCount!=value.descriptor.byteCount ||
            read.source.room!=value.message.room || read.source.message!=value.message.message || !catalog.currentRead(read)) throw ResourceCatalogConflict()
        check(files.files().any {it.state==ResourceFileState.Published && it.checksum==value.descriptor.checksum && it.byteCount==value.descriptor.byteCount}) {"缺少经过校验的下载文件"}
        write(value.copy(phase=ResourceDownloadPhase.Completed,requested=false,owner=null,claim=null,issue=null,finishedAt=maxOf(now,value.createdAt)))
        prune(now)
    }
    fun release(claim:ResourceDownloadClaim,issue:ResourceDownloadIssue,retry:Long?,server:Long,interrupted:Boolean,now:Long) {
        val value=owned(claim) ?: return
        val cancelled=value.control==ResourceDownloadControl.Cancel;val visible=read(value)!=null
        val resume=value.control==ResourceDownloadControl.Run && visible && value.attempts<5 && (interrupted || retry!=null)
        write(value.copy(owner=null,claim=null,phase=if(cancelled) ResourceDownloadPhase.Stopped else ResourceDownloadPhase.Pending,requested=resume,
            issue=when {cancelled || value.control==ResourceDownloadControl.Pause->null;!visible->ResourceDownloadIssue.Unavailable;else->issue},
            retryAt=maxOf(value.retryAt,retry ?: 0),serverRetryAt=maxOf(value.serverRetryAt,server),finishedAt=if(cancelled) maxOf(now,value.createdAt) else null))
        prune(now)
    }

    fun backgroundSession():String {
        db.rawQuery("SELECT id FROM resource_download_session WHERE singleton=1",null).use {if(it.moveToFirst()) return it.getString(0)}
        return UUID.randomUUID().toString().uppercase().also {db.execSQL("INSERT INTO resource_download_session(singleton,id) VALUES(1,?)",arrayOf(it))}
    }
    fun backgrounds():PersistentList<ResourceBackgroundDownloadSnapshot> = db.rawQuery("SELECT id,session,task,job,payload,received FROM resource_background_downloads WHERE completed=0 ORDER BY created,id LIMIT 17",null).use {rows->
        buildList {while(rows.moveToNext()) {
            val value=ResourceBackgroundDownloadMapping.decode(Json.parseToJsonElement(rows.getString(4)).jsonObject)
            require(value.id==rows.getString(0) && value.systemSession==rows.getString(1) && value.task==rows.getString(2) && value.download==rows.getString(3))
            add(ResourceBackgroundDownloadSnapshot(value,rows.getInt(5)==1))
        }}.toPersistentList().also {require(it.size<=16)}
    }
    fun installBackground(claim:ResourceDownloadClaim,id:String,task:String,target:ResourceBackgroundDownloadTarget,now:Long):ResourceBackgroundDownloadMapping {
        require(now>=0)
        val value=requireNotNull(owned(claim)) {"下载执行权已变化"}
        require(value.control==ResourceDownloadControl.Run && value.requested && !value.backgroundPending && read(value)!=null)
        target.remainingLifetimeMillis(value.descriptor,now)
        val preferences=networkPreferences()
        if(value.automatic && !preferences.automaticDownloads.allows(value.descriptor.contentType,value.descriptor.byteCount)) throw ResourceDownloadPolicyRestricted()
        require(backgrounds().size<16)
        val mapping=ResourceBackgroundDownloadMapping(id,backgroundSession(),task,value.id,value.descriptor.key,value.message,target.authorization,
            resourceBackgroundOriginDigest(target.target.plan.url),preferences.constraints(value.automatic),now)
        db.execSQL("INSERT INTO resource_background_downloads(id,session,task,job,payload,created) VALUES(?,?,?,?,?,?)",
            arrayOf(mapping.id,mapping.systemSession,mapping.task,mapping.download,mapping.payload().toString(),mapping.createdAt))
        write(value.copy(phase=ResourceDownloadPhase.Pending,owner=null,claim=null,backgroundPending=true))
        return mapping
    }
    private fun mapped(value:ResourceBackgroundDownloadMapping):ResourceDownloadWork? {
        if(backgrounds().none {it.mapping==value} || value.systemSession!=backgroundSession()) return null
        return work(value.download)?.also {
            require(it.backgroundPending && it.descriptor.key==value.key && it.message==value.message && it.descriptor.byteCount==value.authorization.expectedBytes && it.descriptor.checksum==value.authorization.checksum)
        }
    }
    fun finishBackground(mapping:ResourceBackgroundDownloadMapping,result:ResourceBackgroundDownloadResult?,now:Long):Boolean {
        require(now>=0)
        val value=mapped(mapping) ?: return false
        if(result!=null && (result.mapping!=mapping.id || result.task!=mapping.task)) return false
        val visible=read(value)!=null
        // Once received, a duplicate/late physical callback cannot replace the result. User controls still drain it.
        if(backgrounds().first {it.mapping==mapping}.received && value.control==ResourceDownloadControl.Run && visible) return false
        val same=result?.originDigest==mapping.originDigest
        val success=same && result?.issue==null && result?.status==200 && result.receivedBytes==mapping.authorization.expectedBytes
        if(success && value.control==ResourceDownloadControl.Run && visible) {
            db.execSQL("UPDATE resource_background_downloads SET received=1 WHERE id=?",arrayOf(mapping.id));return true
        }
        val issue=when {
            !visible->ResourceDownloadIssue.Unavailable
            result==null->ResourceDownloadIssue.Interrupted
            result.originDigest!=null && !same->ResourceDownloadIssue.Integrity
            result.issue!=null->requireNotNull(result.issue)
            result.status==401->ResourceDownloadIssue.Authorization
            result.status in setOf(403,404)->ResourceDownloadIssue.Unavailable
            result.status in setOf(408,429) || (result.status ?: 0)>=500->ResourceDownloadIssue.Network
            else->ResourceDownloadIssue.Integrity
        }
        retireBackground(mapping,value,issue,if(same) result?.retryNotBefore ?: 0 else 0,now)
        return true
    }
    fun completeBackground(mapping:ResourceBackgroundDownloadMapping,evidence:MessageResourceRead,now:Long):Boolean {
        require(now>=0);val value=mapped(mapping) ?: return false
        if(!backgrounds().first {it.mapping==mapping}.received || value.control!=ResourceDownloadControl.Run) return false
        require(evidence.descriptor.key==value.descriptor.key && evidence.descriptor.checksum==value.descriptor.checksum && evidence.descriptor.byteCount==value.descriptor.byteCount &&
            evidence.source.room==value.message.room && evidence.source.message==value.message.message && catalog.currentRead(evidence))
        check(files.files().any {it.state==ResourceFileState.Published && it.checksum==value.descriptor.checksum && it.byteCount==value.descriptor.byteCount}) {"缺少经过校验的下载文件"}
        write(value.copy(phase=ResourceDownloadPhase.Completed,requested=false,backgroundPending=false,issue=null,finishedAt=maxOf(now,value.createdAt)))
        retireMapping(mapping);prune(now);return true
    }
    fun discardReceived(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,now:Long):Boolean {
        require(now>=0 && issue in setOf(ResourceDownloadIssue.Integrity,ResourceDownloadIssue.Storage,ResourceDownloadIssue.Unavailable))
        val value=mapped(mapping) ?: return false
        if(!backgrounds().first {it.mapping==mapping}.received) return false
        retireBackground(mapping,value,issue,0,now);return true
    }
    fun failReceived(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,now:Long):Boolean {
        require(now>=0 && serverRetryAt>=0 && (retryAt==null || retryAt>=0))
        require(retryAt==null || issue in setOf(ResourceDownloadIssue.Network,ResourceDownloadIssue.Interrupted))
        val value=mapped(mapping) ?: return false
        if(!backgrounds().first {it.mapping==mapping}.received) return false
        if(retryAt!=null && value.attempts<5 && value.control==ResourceDownloadControl.Run && read(value)!=null) {
            write(value.copy(attempts=value.attempts+1,issue=issue,retryAt=maxOf(value.retryAt,retryAt,serverRetryAt),serverRetryAt=maxOf(value.serverRetryAt,serverRetryAt)))
        } else retireBackground(mapping,value,issue,serverRetryAt,now,allowRetry=false)
        return true
    }
    private fun retireBackground(mapping:ResourceBackgroundDownloadMapping,value:ResourceDownloadWork,issue:ResourceDownloadIssue,server:Long,now:Long,allowRetry:Boolean=true) {
        val cancelled=value.control==ResourceDownloadControl.Cancel;val visible=read(value)!=null
        val retry=allowRetry && value.control==ResourceDownloadControl.Run && visible && value.attempts<5 && issue in setOf(ResourceDownloadIssue.Network,ResourceDownloadIssue.Interrupted)
        val floor=maxOf(value.serverRetryAt,server)
        val delay=minOf(30_000L,1000L shl (value.attempts-1).coerceAtLeast(0))
        val due=if(delay>Long.MAX_VALUE-now) Long.MAX_VALUE else now+delay
        write(value.copy(backgroundPending=false,phase=if(cancelled) ResourceDownloadPhase.Stopped else ResourceDownloadPhase.Pending,requested=retry,
            issue=when {cancelled || value.control==ResourceDownloadControl.Pause->null;!visible->ResourceDownloadIssue.Unavailable;else->issue},
            retryAt=maxOf(value.retryAt,floor,if(retry) due else 0),serverRetryAt=floor,finishedAt=if(cancelled) maxOf(now,value.createdAt) else null))
        retireMapping(mapping);prune(now)
    }
    private fun retireMapping(mapping:ResourceBackgroundDownloadMapping) {
        db.execSQL("UPDATE resource_background_downloads SET completed=1 WHERE id=?",arrayOf(mapping.id))
        db.execSQL("DELETE FROM resource_background_downloads WHERE completed=1 AND id NOT IN(SELECT id FROM resource_background_downloads ORDER BY created DESC,id DESC LIMIT 128)")
    }
}
