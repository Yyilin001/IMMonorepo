package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/** All methods run in the account transaction, including source adoption and final command freezing. */
internal class SqliteProfileIntents(private val db: SQLiteDatabase,private val actor: UserId,
    private val profiles: SqliteOwnProfile,private val resources: SqliteResourceFiles,private val imports: SqliteResourceImports, private val retryExecution: (String, Long) -> Unit) {
    init { if (!db.isReadOnly) { db.execSQL("CREATE TABLE IF NOT EXISTS profile_intents (id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,upload_id TEXT,payload TEXT NOT NULL CHECK(length(payload)<=65536))") } }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(profile_intents)",null).use { rows -> buildSet { while(rows.moveToNext()) add(rows.getString(1)) } }
        if("import_id" !in columns) db.execSQL("ALTER TABLE profile_intents ADD COLUMN import_id TEXT")
        db.execSQL("CREATE INDEX IF NOT EXISTS profile_intent_import ON profile_intents(import_id)")
    } }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(profile_intents)",null).use {r->buildSet {while(r.moveToNext()) add(r.getString(1))}}
        if("owner_live" !in columns) {
            db.execSQL("ALTER TABLE profile_intents ADD COLUMN owner_live INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE profile_intents ADD COLUMN created INTEGER NOT NULL DEFAULT 0")
            all().forEach {put(it)}
        }
        for(column in listOf("upload_id","import_id")) db.execSQL("CREATE INDEX IF NOT EXISTS profile_owner_$column ON profile_intents($column,owner_live,created DESC,id DESC)")
    } }
    private fun all(): List<ProfileIntent> = db.rawQuery("SELECT payload FROM profile_intents ORDER BY rowid",null).use { rows -> buildList {
        while(rows.moveToNext()) add(Json.decodeFromString<ProfileIntent>(rows.getString(0)).also { require(it.actor==actor) })
    } }
    private fun put(intent: ProfileIntent) { db.execSQL("UPDATE profile_intents SET payload=?,owner_live=?,created=? WHERE id=?",arrayOf(Json.encodeToString(intent),if(intent.sourceReleased) 0 else 1,(intent.deadline-86400000).coerceAtLeast(0),intent.id)) }
    fun forOperation(operation: String)=all().firstOrNull { it.operation==operation }
    fun statuses(): PersistentList<ProfileIntentStatus> {
        val works=profiles.works().associateBy { it.command.operation }
        return all().map { intent ->
            val work=if(intent.frozen) requireNotNull(works[intent.operation]).also { require(it.command==intent.command()) } else null
            val phase=when {
                intent.preparation==ProfilePreparation.Cancelled -> ProfileIntentPhase.Closed
                intent.preparation!=ProfilePreparation.Pending -> ProfileIntentPhase.NeedsAttention
                work?.status==OwnProfileStatus.Committed -> ProfileIntentPhase.Committed
                work?.status==OwnProfileStatus.Closed -> ProfileIntentPhase.Closed
                work?.status==OwnProfileStatus.NeedsAttention || work?.terminal==true -> ProfileIntentPhase.NeedsAttention
                work?.submissionStarted==true -> ProfileIntentPhase.Confirming
                work==null && (intent.upload!=null || intent.serverImport!=null) -> ProfileIntentPhase.PreparingAvatar
                else -> ProfileIntentPhase.WaitingToSubmit
            }
            ProfileIntentStatus(intent,work,phase,intent.locallyTerminal || work?.terminal==true)
        }.toPersistentList()
    }
    private fun unfinished(status: ProfileIntentStatus)=!status.intent.locallyTerminal && status.work?.terminal!=true
    fun deadline(): Long?=statuses().firstOrNull(::unfinished)?.intent?.takeUnless { it.frozen }?.deadline
    fun requireNoWaitingIntent() { check(statuses().none { unfinished(it) && !it.intent.frozen }) { "请先处理正在准备的资料修改" } }
    fun enqueue(intent: ProfileIntent,now: Long,adopting: ProfileIntent?=null): ProfileIntent {
        require(intent.actor==actor && !intent.frozen && intent.preparation==ProfilePreparation.Pending && !intent.sourceReleased)
        require(now>=0 && intent.deadline==Math.addExact(now,86400000))
        val baseline=profiles.read() ?: error("请先刷新本人资料")
        require(baseline.state==ProfileState.Active && baseline.revision==intent.revision) { "资料版本已变化，请刷新后重试" }
        val existing=statuses();val linked=existing.map { it.intent.operation }.toSet()
        val external=profiles.works().filter { it.command.operation !in linked }
        check(existing.count { it.sourceRetained }+external.count { it.draftRetained }<128 || adopting!=null) { "请先处理保留的资料草稿" }
        intent.upload?.let { source ->
            val asset=resources.assets().first { it.id==source.asset }
            require(asset.purpose==ResourceUsage.UserAvatar && asset.displayName==source.displayName && asset.contentType==source.contentType && asset.byteCount==source.byteCount)
            require(resources.uploads().none { it.id==source.id } || adopting?.upload?.id==source.id)
            resources.bindProfile(source.asset,ProfileOriginalConsumer(intent.id),adopting?.let { ProfileOriginalConsumer(it.id) })
        }
        intent.serverImport?.let { source ->
            val work=imports.prepare(source.id,source.request,now)
            require(work.request==source.request && work.request.targetUsage==ResourceUsage.UserAvatar)
            imports.bind(source.id,ProfileOriginalConsumer(intent.id))
        }
        existing.filter { !it.sourceRetained && !unfinished(it) }.dropLast(127).forEach { db.execSQL("DELETE FROM profile_intents WHERE id=?",arrayOf(it.intent.id)) }
        db.execSQL("INSERT INTO profile_intents(id,operation,upload_id,payload,import_id) VALUES (?,?,?,?,?)",arrayOf(intent.id,intent.operation,intent.upload?.id,Json.encodeToString(intent),intent.serverImport?.id))
        put(intent)
        return intent
    }
    private fun renew(work: ResourceUploadWork,now: Long)=work.cancellationRequested || work.stage in setOf(ResourceUploadStage.Cancelled,ResourceUploadStage.Rejected,ResourceUploadStage.Expired) ||
        if(work.stage==ResourceUploadStage.Ready) work.session?.bindable(now)!=true else work.session?.expiresAt?.let { it<=now }==true

    fun replace(id: String,newId: String,newOperation: String,newUpload: String,revision: Long,now: Long): ProfileIntent {
        val status=statuses().first { it.intent.id==id };val old=status.intent
        require(status.canReplace && status.sourceRetained && status.phase!=ProfileIntentPhase.Committed)
        val source=old.upload?.let { original ->
            val work=resources.uploads().firstOrNull { it.id==original.id }
            if(work!=null && renew(work,now)) original.copy(id=newUpload) else original
        }
        val imported=old.serverImport?.let { original ->
            ProfileAvatarImport(newUpload,original.request.copy(operation=java.util.UUID.randomUUID().toString().uppercase(),targetMedia=java.util.UUID.randomUUID().toString().uppercase()))
        }
        val next=ProfileIntent(newId,actor,newOperation,revision,Math.addExact(now,86400000),old.name,old.avatar,source,serverImport=imported)
        enqueue(next,now,old);discard(id);return next
    }
    fun resume(id: String,now: Long): ProfileIntent? {
        val status=statuses().first { it.intent.id==id };val intent=status.intent
        require(status.sourceRetained)
        status.work?.let { work ->
            if(work.terminal) return null
            if(work.status==OwnProfileStatus.NeedsAttention) retryExecution(work.command.operation,now)
            return intent
        }
        if(intent.locallyTerminal && !(intent.preparation==ProfilePreparation.Failed && intent.serverImport!=null)) return null
        if(intent.deadline<=now) { put(intent.copy(preparation=ProfilePreparation.Expired));return null }
        intent.serverImport?.let { source ->
            val work=imports.all().first { it.id==source.id };require(work.request==source.request)
            imports.requireConsumer(source.id,ProfileOriginalConsumer(intent.id))
            if(work.cancellationRequested || work.businessBound || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed)) { put(intent.copy(preparation=ProfilePreparation.Failed));return null }
            if(work.status?.state==ResourceImportState.Ready && work.status?.bindable(now)!=true) { put(intent.copy(preparation=ProfilePreparation.Expired));return null }
            if(work.execution.owner!=null) return intent
            if(!work.terminal) imports.control(source.id,false,true)
        }
        intent.upload?.let { source -> resources.uploads().firstOrNull { it.id==source.id }?.let { work ->
            if(renew(work,now)) { put(intent.copy(preparation=ProfilePreparation.Failed));return null }
            if(!work.terminal && (work.execution.attention || work.execution.userPaused)) resources.control(work.id,false,work.execution.attention)
        } }
        return intent.copy(preparation=ProfilePreparation.Pending).also { if(it!=intent) put(it) }
    }
    fun discard(id: String) {
        val status=statuses().first { it.intent.id==id };val intent=status.intent
        if(intent.sourceReleased) return
        require(status.work?.terminal!=false) { "原资料修改结果尚未确认" }
        if(status.work?.draftRetained==true) profiles.discard(intent.operation)
        intent.upload?.let { resources.releaseProfile(ProfileOriginalConsumer(intent.id)) }
        intent.serverImport?.let { imports.releaseConsumer(it.id,ProfileOriginalConsumer(intent.id)) }
        put(intent.copy(sourceReleased=true,preparation=if(intent.frozen) intent.preparation else ProfilePreparation.Cancelled))
        releaseUnusedUploads()
        releaseUnusedImports()
    }
    /** A verified committed receipt atomically releases the business source, even after process reopen. */
    fun reconcile() {
        statuses().filter { it.phase==ProfileIntentPhase.Committed && it.sourceRetained }.forEach {
            it.intent.upload?.let { _ -> resources.releaseProfile(ProfileOriginalConsumer(it.intent.id)) }
            it.intent.serverImport?.let { source -> imports.releaseConsumer(source.id,ProfileOriginalConsumer(it.intent.id),committed=true) }
            put(it.intent.copy(sourceReleased=true))
        }
        releaseUnusedUploads()
        releaseUnusedImports()
    }
    private fun releaseUnusedUploads() {
        val intents=all()
        val jobs=resources.uploads().associateBy { it.id }
        for((upload,consumers) in intents.filter { it.upload!=null }.groupBy { it.upload!!.id }) {
            if(consumers.any { !it.sourceReleased }) continue
            val work=jobs[upload] ?: continue
            if(work.sourceReleased) continue
            if(work.terminal) { if(work.execution.owner==null) resources.release(upload) }
            else if(!work.cancellationRequested) resources.cancel(upload)
        }
    }
    private fun releaseUnusedImports() {
        val jobs=imports.all().associateBy { it.id }
        for(intent in all().filter { it.serverImport!=null && it.sourceReleased }) {
            val work=jobs[intent.serverImport!!.id] ?: continue
            if(work.businessBound || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed) || work.cancellationResolved) {
                if(work.terminal && work.execution.owner==null) imports.release(work.id)
            } else if(!work.cancellationRequested) imports.cancel(work.id)
        }
    }
    fun advance(now: Long) {
        reconcile()
        val intent=statuses().firstOrNull(::unfinished)?.intent ?: return
        if(intent.frozen) return
        if(intent.deadline<=now) { put(intent.copy(preparation=ProfilePreparation.Expired));return }
        if(intent.preparation==ProfilePreparation.NeedsAttention) return
        // Existing low-level work finishes first; the original captured revision is never silently refreshed.
        if(profiles.works().any { !it.terminal }) return
        intent.upload?.let { source ->
            val asset=try { resources.original(null,null,ProfileOriginalConsumer(intent.id)) }
                catch(_: NoSuchElementException) { null } catch(_: IllegalArgumentException) { null }
            if(asset==null) { put(intent.copy(preparation=ProfilePreparation.Failed));return }
            var work=resources.uploads().firstOrNull { it.id==source.id }
            if(work==null) {
                if(resources.uploads().count { !it.terminal }+imports.all().count { !it.terminal }>=32) return
                val request=ResourceUploadRequest(source.id,source.id,ResourceUsage.UserAvatar,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName,dimensions=asset.dimensions)
                work=resources.prepare(source.id,source.asset,request,ProfileOriginalConsumer(intent.id))
            }
            require(work.asset==source.asset && work.request.media==source.id && work.request.usage==ResourceUsage.UserAvatar)
            if(renew(work,now)) { put(intent.copy(preparation=if(work.stage==ResourceUploadStage.Ready) ProfilePreparation.Expired else ProfilePreparation.Failed));return }
            if(work.execution.attention || work.execution.userPaused) { put(intent.copy(preparation=ProfilePreparation.NeedsAttention));return }
            if(work.stage!=ResourceUploadStage.Ready || work.session?.bindable(now)!=true || work.execution.owner!=null) return
        }
        intent.serverImport?.let { source ->
            val work=imports.all().first { it.id==source.id };require(work.request==source.request)
            imports.requireConsumer(source.id,ProfileOriginalConsumer(intent.id))
            if(work.businessBound || work.cancellationRequested || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed)) { put(intent.copy(preparation=ProfilePreparation.Failed));return }
            if(work.status?.state==ResourceImportState.Ready && work.status?.bindable(now)!=true) { put(intent.copy(preparation=ProfilePreparation.Expired));return }
            if(work.execution.attention || work.execution.paused) { put(intent.copy(preparation=ProfilePreparation.NeedsAttention));return }
            if(!work.bindable(now)) return
        }
        val frozen=intent.copy(frozen=true)
        profiles.enqueue(frozen.command(),null,requireCurrentBaseline=false,now=now);put(frozen)
    }
}
