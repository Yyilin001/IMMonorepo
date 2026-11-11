package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.util.UUID

/** All transitions and independent source references commit in the account's writer transaction. */
internal class SqliteGroupAvatarIntents(private val db: SQLiteDatabase,private val actor: UserId,private val device: DeviceId,
    private val resources: SqliteResourceFiles,private val avatars: SqliteGroupAvatars,private val imports: SqliteResourceImports) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS group_avatar_intents (id TEXT PRIMARY KEY,room TEXT NOT NULL,upload_id TEXT,replacement_of TEXT UNIQUE,payload TEXT NOT NULL CHECK(length(payload)<=65536))")
        db.execSQL("CREATE INDEX IF NOT EXISTS group_avatar_intents_room ON group_avatar_intents(room)")
        val columns=db.rawQuery("PRAGMA table_info(group_avatar_intents)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("import_id" !in columns) db.execSQL("ALTER TABLE group_avatar_intents ADD COLUMN import_id TEXT")
        db.execSQL("CREATE INDEX IF NOT EXISTS group_avatar_intents_import ON group_avatar_intents(import_id)")
    } }
    init { if (!db.isReadOnly) {
        val columns=db.rawQuery("PRAGMA table_info(group_avatar_intents)",null).use {r->buildSet {while(r.moveToNext()) add(r.getString(1))}}
        if("owner_live" !in columns) {
            db.execSQL("ALTER TABLE group_avatar_intents ADD COLUMN owner_live INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE group_avatar_intents ADD COLUMN created INTEGER NOT NULL DEFAULT 0")
            all().forEach {put(it)}
        }
        for(column in listOf("upload_id","import_id")) db.execSQL("CREATE INDEX IF NOT EXISTS group_owner_$column ON group_avatar_intents($column,owner_live,created DESC,id DESC)")
    } }
    fun all()=db.rawQuery("SELECT id,room,upload_id,payload,replacement_of,import_id FROM group_avatar_intents ORDER BY rowid",null).use { rows -> buildList {
        while(rows.moveToNext()) add(Json.decodeFromString<GroupAvatarIntent>(rows.getString(3)).also {
            require(it.actor==actor && it.device==device && it.id==rows.getString(0) && it.command.room.value==rows.getString(1) && it.upload==rows.getString(2) && it.replacementOf==rows.getString(4) && it.serverImport?.id==rows.getString(5))
        })
    }.toPersistentList() }
    fun find(id: String) = db.rawQuery("SELECT id,room,upload_id,payload,replacement_of,import_id FROM group_avatar_intents WHERE id=?", arrayOf(id)).use { rows ->
        if(rows.moveToFirst()) Json.decodeFromString<GroupAvatarIntent>(rows.getString(3)).also {
            require(it.actor==actor && it.device==device && it.id==rows.getString(0) && it.command.room.value==rows.getString(1) && it.upload==rows.getString(2) && it.replacementOf==rows.getString(4) && it.serverImport?.id==rows.getString(5))
        } else null
    }
    private fun get(id: String)=find(id) ?: throw NoSuchElementException("Group avatar intent not found")
    private fun put(value: GroupAvatarIntent) { db.execSQL("UPDATE group_avatar_intents SET payload=?,owner_live=?,created=? WHERE id=?",arrayOf(Json.encodeToString(value),if(value.pending) 1 else 0,value.createdAt,value.id)) }
    private fun checkAuthority(authority: GroupAvatarEditAuthority,room: RoomId,revision: Long) {
        val value=authority.presentation
        require(value.actor==actor && value.device==device && value.state.room==room && value.state.revision==revision && value.canManage && value.valid())
        val current=avatars.fence(room)
        require(current==authority.fence && current.authorized && revision>=current.revision && value.membershipRevision>=current.membershipRevision) { "群权限已变化，请刷新后重试" }
    }
    fun enqueue(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,upload: GroupAvatarUploadPreparation?,now: Long,adopting: GroupAvatarIntent?=null,serverImport: GroupAvatarImportPreparation?=null): GroupAvatarIntent {
        require(now>=0)
        all().firstOrNull { it.id==command.operation }?.let { old ->
            require(old.command==command && old.upload==upload?.id && old.asset==upload?.asset && old.serverImport==serverImport)
            upload?.let { require(resources.uploads().first { work -> work.id==it.id }.request==it.request) };return old
        }
        checkAuthority(authority,command.room,command.revision)
        val existing=all();check(existing.none { it.command.room==command.room && !it.terminal }) { "请先确认原群头像操作" }
        check(existing.count { !it.terminal }<32 && (existing.count { it.pending }<128 || adopting!=null)) { "待处理群头像任务过多" }
        require(upload==null || serverImport==null)
        require((command.mutation==GroupAvatarMutation.Remove)==(upload==null && serverImport==null))
        serverImport?.let {
            require(it.request.targetUsage==ResourceUsage.GroupAvatar(command.room) && command.mutation.mediaId==it.request.targetMedia)
            require(resources.uploads().none {work->work.id==it.id || work.request.media==it.request.targetMedia})
            imports.prepare(it.id,it.request,now);imports.bind(it.id,GroupAvatarOriginalConsumer(command.operation))
        }
        upload?.let {
            require(command.mutation.mediaId==it.request.media && it.request.usage==ResourceUsage.GroupAvatar(command.room))
            require(resources.uploads().none { work -> work.id==it.id })
            require(imports.all().none {work->work.id==it.id || work.request.targetMedia==it.request.media})
            val consumer=GroupAvatarOriginalConsumer(command.operation)
            resources.bindGroup(it.asset,command.room,consumer,adopting?.let { prior -> GroupAvatarOriginalConsumer(prior.id) })
            resources.prepare(it.id,it.asset,it.request,group=consumer)
        }
        val uploads=resources.uploads().associateBy { it.id }
        existing.filter { !it.pending && it.sourceReleased && it.claim==null && (it.upload==null || uploads[it.upload]?.let { work -> work.sourceReleased && work.execution.owner==null }==true) }.dropLast(127).forEach { db.execSQL("DELETE FROM group_avatar_intents WHERE id=?",arrayOf(it.id)) }
        val value=GroupAvatarIntent(actor,device,command,now,upload?.id,upload?.asset,serverImport=serverImport,replacementOf=adopting?.id)
        db.execSQL("INSERT INTO group_avatar_intents(id,room,upload_id,replacement_of,payload,import_id) VALUES (?,?,?,?,?,?)",arrayOf(value.id,command.room.value,value.upload,value.replacementOf,Json.encodeToString(value),serverImport?.id))
        put(value)
        return value
    }
    private fun release(value: GroupAvatarIntent): GroupAvatarIntent {
        if(!value.sourceReleased) {
            if(value.upload!=null) resources.releaseGroup(GroupAvatarOriginalConsumer(value.id))
            value.serverImport?.let {imports.releaseConsumer(it.id,GroupAvatarOriginalConsumer(value.id),committed=value.stage==GroupAvatarStage.Committed)}
        }
        return value.copy(sourceReleased=true)
    }
    private fun cleanupUploads() {
        val intents=all()
        val uploads=resources.uploads().associateBy { it.id }
        for((id,consumers) in intents.filter { it.upload!=null }.groupBy { it.upload!! }) {
            if(consumers.any { !it.sourceReleased }) continue
            val work=uploads[id] ?: continue
            if(work.sourceReleased) continue
            if(work.terminal) { if(work.execution.owner==null) resources.release(id) }
            else if(!work.cancellationRequested) resources.cancel(id)
        }
        val imported=imports.all().associateBy {it.id}
        for((id,consumers) in intents.filter {it.serverImport!=null}.groupBy {it.serverImport!!.id}) {
            if(consumers.any {!it.sourceReleased}) continue
            val work=imported[id] ?: continue
            if(work.businessBound || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed) || work.cancellationResolved) {
                if(work.terminal && work.execution.owner==null) imports.release(id)
            } else if(!work.cancellationRequested) imports.cancel(id)
        }
    }
    private fun importReady(value: GroupAvatarIntent,now: Long): Boolean {
        val source=value.serverImport ?: return true
        val work=imports.all().firstOrNull {it.id==source.id} ?: return false
        require(work.request==source.request)
        imports.requireConsumer(source.id,GroupAvatarOriginalConsumer(value.id))
        return work.bindable(now)
    }
    private fun departed(room: RoomId)=db.rawQuery("SELECT member FROM memberships WHERE room=?",arrayOf(room.value)).use { it.moveToFirst() && it.getInt(0)==0 }
    fun prepare(now: Long) {
        require(now>=0)
        for(saved in all()) {
            var value=saved
            if(value.claimUntil?.let { it<=now }==true) {
                value=value.copy(claim=null,claimUntil=null,action=value.action ?: GroupAvatarRecoveryAction.Query,issue=GroupAvatarIssue.OutcomeUnknown)
                put(value)
            }
            if(value.claim!=null) continue
            if(departed(value.command.room) && value.pending) {
                when {
                    !value.submissionStarted -> { put(release(value.copy(stage=GroupAvatarStage.Cancelled,issue=null)));continue }
                    value.stage==GroupAvatarStage.Closed -> { put(release(value.copy(disposition=GroupAvatarDisposition.Abandoned)));continue }
                    value.action!=GroupAvatarRecoveryAction.CloseIfAbsent -> {
                        value=value.copy(stage=GroupAvatarStage.Submitted,action=GroupAvatarRecoveryAction.CloseIfAbsent,attempts=0,retryAt=maxOf(value.retryAt,value.serverRetryAt),issue=null);put(value)
                    }
                }
            }
            if(value.terminal) continue
            if(value.submissionStarted && (value.stage==GroupAvatarStage.NeedsAttention || value.attempts>=5) && maxOf(value.retryAt,value.serverRetryAt)<=now) {
                val next=if(value.action==GroupAvatarRecoveryAction.CloseIfAbsent) Math.addExact(now,60000) else now
                value=value.copy(stage=GroupAvatarStage.Submitted,action=GroupAvatarRecoveryAction.CloseIfAbsent,attempts=0,retryAt=maxOf(next,value.serverRetryAt),issue=null);put(value)
            }
            if(!value.submissionStarted && value.serverImport!=null && value.stage in setOf(GroupAvatarStage.Preparing,GroupAvatarStage.NeedsAttention)) {
                val source=value.serverImport!!;val work=imports.all().first {it.id==source.id};require(work.request==source.request)
                imports.requireConsumer(source.id,GroupAvatarOriginalConsumer(value.id))
                val unavailable=work.businessBound || work.cancellationRequested || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed) ||
                    work.status?.state==ResourceImportState.Ready && work.status?.bindable(now)!=true ||
                    !work.terminal && (work.execution.attention || work.execution.paused)
                val next=if(unavailable) value.copy(stage=GroupAvatarStage.NeedsAttention,issue=GroupAvatarIssue.PreparationUnavailable)
                    else value.copy(stage=GroupAvatarStage.Preparing,issue=null)
                if(next!=value) {value=next;put(value)}
            }
            if(value.stage==GroupAvatarStage.Preparing && value.upload!=null) {
                val upload=resources.uploads().firstOrNull { it.id==value.upload }
                val original=try { resources.groupOriginal(GroupAvatarOriginalConsumer(value.id)) } catch(_: NoSuchElementException) { null } catch(_: IllegalArgumentException) { null }
                if(original==null || upload==null || upload.cancellationRequested || upload.execution.attention || upload.stage in setOf(ResourceUploadStage.Cancelled,ResourceUploadStage.Rejected,ResourceUploadStage.Expired) || upload.stage==ResourceUploadStage.Ready && upload.session?.bindable(now)!=true)
                    put(value.copy(stage=GroupAvatarStage.NeedsAttention,issue=GroupAvatarIssue.PreparationUnavailable))
            }
        }
        cleanupUploads()
    }
    fun due(now: Long): kotlinx.collections.immutable.PersistentList<String> {
        val uploads=resources.uploads().associateBy { it.id }
        return all().filter { value ->
            value.claim==null && value.stage in setOf(GroupAvatarStage.Preparing,GroupAvatarStage.Submitted) && value.attempts<5 && maxOf(value.retryAt,value.serverRetryAt)<=now &&
                (value.submissionStarted || if(value.serverImport!=null) importReady(value,now) else value.upload==null || uploads[value.upload]?.let { it.stage==ResourceUploadStage.Ready && !it.cancellationRequested && it.session?.bindable(now)==true && it.execution.owner==null }==true)
        }.sortedWith(compareBy<GroupAvatarIntent> { maxOf(it.retryAt,it.serverRetryAt) }.thenBy { it.createdAt }.thenBy { it.id }).map { it.id }.toPersistentList()
    }
    fun claim(id: String,now: Long): GroupAvatarClaim? {
        val old=get(id)
        if(old.stage !in setOf(GroupAvatarStage.Preparing,GroupAvatarStage.Submitted) || old.claim!=null || maxOf(old.retryAt,old.serverRetryAt)>now || old.attempts>=5) return null
        if(!old.submissionStarted && (departed(old.command.room) || !importReady(old,now))) return null
        if(!old.submissionStarted && old.upload!=null) {
            val upload=resources.uploads().first { it.id==old.upload }
            if(upload.stage!=ResourceUploadStage.Ready || upload.cancellationRequested || upload.session?.bindable(now)!=true || upload.execution.owner!=null) return null
            resources.groupOriginal(GroupAvatarOriginalConsumer(id))
        }
        val token=UUID.randomUUID().toString().uppercase()
        val next=old.copy(stage=GroupAvatarStage.Submitted,submissionStarted=true,attempts=old.attempts+1,claim=token,claimUntil=Math.addExact(now,30000),issue=null)
        put(next);return GroupAvatarClaim(next,token)
    }
    private fun validate(claim: GroupAvatarClaim): GroupAvatarIntent=get(claim.intent.id).also {
        require(it.command==claim.intent.command && it.actor==claim.intent.actor && it.device==claim.intent.device && it.submissionStarted)
    }
    private fun committed(current: GroupAvatarIntent,receipt: GroupAvatarChange) {
        require(current.stage!=GroupAvatarStage.Closed && current.stage!=GroupAvatarStage.Cancelled)
        if(current.receipt!=null) { require(current.receipt==receipt);return }
        put(release(current.copy(stage=GroupAvatarStage.Committed,receipt=receipt,claim=null,claimUntil=null,issue=null)))
        cleanupUploads()
    }
    fun finish(claim: GroupAvatarClaim,response: GroupAvatarCommandResponse,now: Long) {
        val current=validate(claim);require(response.actor==actor && response.device==device && response.command==current.command)
        when(val result=response.outcome) {
            is GroupAvatarOutcome.Committed -> committed(current,result.change)
            else -> fail(claim,when(result) {
                GroupAvatarOutcome.RevisionConflict -> GroupAvatarIssue.RevisionConflict
                GroupAvatarOutcome.IdempotencyConflict -> GroupAvatarIssue.IdempotencyConflict
                GroupAvatarOutcome.ResourceUnavailable -> GroupAvatarIssue.ResourceUnavailable
                else -> GroupAvatarIssue.Forbidden
            },now,true)
        }
    }
    fun finishRecovery(claim: GroupAvatarClaim,response: GroupAvatarRecoveryResponse,now: Long) {
        val current=validate(claim)
        require(response.actor==actor && response.device==device && response.request.command==current.command && response.request.action==claim.intent.action)
        when(val result=response.result) {
            is GroupAvatarRecoveryResult.Committed -> committed(current,result.change)
            GroupAvatarRecoveryResult.Closed -> {
                require(current.stage!=GroupAvatarStage.Committed && current.stage!=GroupAvatarStage.Cancelled)
                if(current.stage==GroupAvatarStage.Closed) return
                put(current.copy(stage=GroupAvatarStage.Closed,proof=GroupAvatarClosureProof(actor,device,response.request),claim=null,claimUntil=null,issue=null))
            }
            GroupAvatarRecoveryResult.IdempotencyConflict -> fail(claim,GroupAvatarIssue.IdempotencyConflict,now,true)
            GroupAvatarRecoveryResult.Unresolved -> {
                val owned=fail(claim,GroupAvatarIssue.OutcomeUnknown,Math.addExact(now,5000),false)
                if(owned && current.action==GroupAvatarRecoveryAction.Query) put(get(current.id).copy(action=null))
            }
        }
    }
    fun fail(claim: GroupAvatarClaim,issue: GroupAvatarIssue,retryAt: Long,attention: Boolean,serverRetryAt: Long=0): Boolean {
        val current=validate(claim)
        if(current.claim!=claim.token || current.stage!=GroupAvatarStage.Submitted) return false
        val server=maxOf(current.serverRetryAt,serverRetryAt)
        if(current.action!=claim.intent.action) {
            put(current.copy(attempts=0,retryAt=server,serverRetryAt=server,claim=null,claimUntil=null,issue=null));return false
        }
        put(current.copy(stage=if(attention || current.attempts>=5) GroupAvatarStage.NeedsAttention else GroupAvatarStage.Submitted,
            retryAt=maxOf(retryAt,server),serverRetryAt=server,issue=issue,claim=null,claimUntil=null,
            action=if(!attention && issue==GroupAvatarIssue.OutcomeUnknown && current.action==null) GroupAvatarRecoveryAction.Query else current.action))
        return true
    }
    fun retry(id: String) {
        val current=get(id);if(current.stage!=GroupAvatarStage.NeedsAttention || current.claim!=null) return
        if(!current.submissionStarted && current.upload!=null) {
            val upload=resources.uploads().first { it.id==current.upload }
            if(!upload.terminal && (upload.execution.attention || upload.execution.userPaused)) resources.control(upload.id,false,upload.execution.attention)
        }
        if(!current.submissionStarted) current.serverImport?.let {source->
            val work=imports.all().first {it.id==source.id};require(work.request==source.request)
            imports.requireConsumer(source.id,GroupAvatarOriginalConsumer(current.id))
            if(!work.terminal && work.execution.owner==null && (work.execution.attention || work.execution.paused)) imports.control(source.id,false,work.execution.attention)
        }
        put(current.copy(stage=if(current.submissionStarted) GroupAvatarStage.Submitted else GroupAvatarStage.Preparing,attempts=0,retryAt=current.serverRetryAt,issue=null))
    }
    fun requestRecovery(id: String,action: GroupAvatarRecoveryAction) {
        val value=get(id);if(value.terminal || value.action==GroupAvatarRecoveryAction.CloseIfAbsent && action!=value.action) return
        // A query must not mark an unsubmitted image as submitted and thereby bypass upload readiness.
        require(value.submissionStarted || action==GroupAvatarRecoveryAction.CloseIfAbsent)
        if(value.action==action && value.stage!=GroupAvatarStage.NeedsAttention) return
        put(value.copy(stage=GroupAvatarStage.Submitted,submissionStarted=true,action=action,attempts=0,retryAt=value.serverRetryAt,issue=null))
    }
    fun cancel(id: String) {
        val value=get(id);if(value.stage==GroupAvatarStage.Cancelled) return
        require(!value.submissionStarted)
        put(release(value.copy(stage=GroupAvatarStage.Cancelled,issue=null)));cleanupUploads()
    }
    fun abandon(id: String) {
        val value=get(id);require(value.stage==GroupAvatarStage.Closed && value.disposition!=GroupAvatarDisposition.Replaced)
        put(release(value.copy(disposition=GroupAvatarDisposition.Abandoned)));cleanupUploads()
    }
    fun replace(id: String,authority: GroupAvatarEditAuthority,operation: String,upload: String,media: String,now: Long): GroupAvatarIntent {
        all().firstOrNull { it.replacementOf==id }?.let { return it }
        val old=get(id);require(old.stage==GroupAvatarStage.Closed && old.disposition==GroupAvatarDisposition.AwaitingDecision)
        val preparation=old.upload?.let { original ->
            val work=resources.uploads().first { it.id==original };require(!old.sourceReleased)
            val request=work.request.copy(operation=UUID.randomUUID().toString().uppercase(),media=media)
            GroupAvatarUploadPreparation(upload,requireNotNull(old.asset),request)
        }
        val imported=old.serverImport?.let {source->
            require(!old.sourceReleased)
            GroupAvatarImportPreparation(upload,source.request.copy(operation=UUID.randomUUID().toString().uppercase(),targetMedia=media))
        }
        val next=enqueue(authority,GroupAvatarCommand(operation,old.command.room,authority.presentation.state.revision,
            preparation?.let { GroupAvatarMutation.Set(it.request.media) } ?: imported?.let {GroupAvatarMutation.Set(it.request.targetMedia)} ?: GroupAvatarMutation.Remove),preparation,now,old,imported)
        put(release(old.copy(disposition=GroupAvatarDisposition.Replaced)));cleanupUploads();return next
    }
}
