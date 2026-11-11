package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/** Caller holds the account transaction for every mutation, including upload adoption and outbox insertion. */
internal class SqliteSendIntents(private val db: SQLiteDatabase,private val actor: UserId,private val resources: SqliteResourceFiles,private val imports: SqliteResourceImports,
    private val revoked: (String)->Boolean,private val enqueueOutbox: (MessageSendOperation)->Unit) {
    init { if (!db.isReadOnly) {
        db.execSQL("CREATE TABLE IF NOT EXISTS send_intents(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,payload TEXT NOT NULL CHECK(length(payload)<=524288))")
        val columns=db.rawQuery("PRAGMA table_info(send_intents)",null).use {rows->buildSet {while(rows.moveToNext()) add(rows.getString(1))}}
        if("cancel_unfinished_only" !in columns) db.execSQL("ALTER TABLE send_intents ADD COLUMN cancel_unfinished_only INTEGER NOT NULL DEFAULT 0")
        val schema = db.rawQuery("SELECT sql FROM sqlite_master WHERE type='table' AND name='send_intents'", null).use { it.moveToFirst(); it.getString(0) }
        if (schema.contains("131072")) {
            val definitions = db.rawQuery("SELECT sql FROM sqlite_master WHERE tbl_name='send_intents' AND type IN ('index','trigger') AND sql IS NOT NULL", null).use { rows ->
                buildList { while (rows.moveToNext()) add(rows.getString(0)) }
            }
            db.execSQL("CREATE TABLE send_intents_text_v2(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,payload TEXT NOT NULL CHECK(length(payload)<=524288),cancel_unfinished_only INTEGER NOT NULL DEFAULT 0)")
            db.execSQL("INSERT INTO send_intents_text_v2 SELECT id,operation,payload,cancel_unfinished_only FROM send_intents")
            db.execSQL("DROP TABLE send_intents")
            db.execSQL("ALTER TABLE send_intents_text_v2 RENAME TO send_intents")
            definitions.forEach(db::execSQL)
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS send_intent_imports(intent TEXT NOT NULL,ordinal INTEGER NOT NULL,import_id TEXT UNIQUE NOT NULL,PRIMARY KEY(intent,ordinal))")
        db.execSQL("CREATE TABLE IF NOT EXISTS send_intent_attachments(intent TEXT NOT NULL,ordinal INTEGER NOT NULL,upload_id TEXT UNIQUE NOT NULL,PRIMARY KEY(intent,ordinal))")
    } }
    private fun all()=db.rawQuery("SELECT payload FROM send_intents ORDER BY rowid",null).use { rows -> buildList {
        while(rows.moveToNext()) add(Json.decodeFromString<SendIntent>(rows.getString(0)).also { require(it.actor==actor) })
    } }
    private fun put(intent: SendIntent) { db.execSQL("UPDATE send_intents SET payload=? WHERE id=?",arrayOf(Json.encodeToString(intent),intent.id)) }
    private fun command(operation: String)=db.rawQuery("SELECT command FROM outbox WHERE id=?",arrayOf(operation)).use { if(it.moveToFirst()) MessageSendOperation.parseFrom(it.getBlob(0)) else null }
    private fun receipt(operation: String)=db.rawQuery("SELECT receipt FROM outbox WHERE id=?",arrayOf(operation)).use { if(it.moveToFirst() && !it.isNull(0)) MessageSendOperationReceipt.parseFrom(it.getBlob(0)) else null }
    fun validateReceipt(operation: String,value: MessageSendOperationReceipt) {
        if(all().none { it.operation==operation }) return
        val command=requireNotNull(command(operation))
        require(value.identity.accountId==actor.value && value.identity.roomId==command.roomId && value.identity.operationId==operation &&
            value.fingerprint.version==command.fingerprintVersion && value.fingerprint.digest==command.fingerprint && value.resolvedAtMs>0 &&
            (value.hasAccepted() && value.accepted.messageId.isNotBlank() && value.accepted.roomSequence>0 || value.hasRejected() && value.rejected.reasonValue in 1..6))
        receipt(operation)?.let { require(it==value) { "发送结果不能被覆盖" } }
    }
    fun statuses(): PersistentList<SendIntentStatus> = all().map { intent ->
        val recovery=if(intent.preparation==SendPreparation.HandedOff) db.rawQuery("SELECT send_work FROM outbox WHERE id=?",arrayOf(intent.operation)).use {
            if(it.moveToFirst() && !it.isNull(0)) Json.decodeFromString<SendRecovery>(it.getString(0)).status else SendRecoveryStatus.Confirming
        } else null
        val phase=when(intent.preparation) {
            SendPreparation.Preparing->SendIntentPhase.Preparing
            SendPreparation.NeedsAttention,SendPreparation.Failed->SendIntentPhase.NeedsAttention
            SendPreparation.Expired->SendIntentPhase.Expired
            SendPreparation.Cancelled->SendIntentPhase.Cancelled
            SendPreparation.HandedOff->{
                val saved=requireNotNull(command(intent.operation));require(saved.roomId==intent.room.value && saved.senderUserId==actor.value && saved.text==intent.text && saved.mediaIdsList==intent.mediaIds && MessageRichContent.fromCommand(saved)==intent.rich)
                val result=receipt(intent.operation)
                when { result==null && recovery==SendRecoveryStatus.ExpiredUnsubmitted->SendIntentPhase.Expired;result==null->SendIntentPhase.Confirming;result.hasAccepted()->SendIntentPhase.Accepted;result.hasRejected()->when(result.rejected.reasonValue) { 1->SendIntentPhase.Expired;6->SendIntentPhase.Closed;else->SendIntentPhase.Rejected };else->throw ClientFailure.Protocol() }
            }
        }
        SendIntentStatus(intent,phase,recovery)
    }.toPersistentList()
    fun enqueue(intent: SendIntent,now: Long,adopting: SendIntent?=null): SendIntent {
        require(intent.actor==actor && intent.preparation==SendPreparation.Preparing && !intent.sourcesReleased)
        all().firstOrNull { it.id==intent.id }?.let { existing ->
            require(adopting==null && existing.copy(preparation=SendPreparation.Preparing,sourcesReleased=false)==intent) { "发送意图身份冲突" }
            return existing
        }
        require(intent.preparationStartedAt<=now && now<intent.deadline)
        check(!revoked(intent.room.value)) { "此会话已不可访问，消息未保存" }
        val statuses=statuses()
        check(statuses.count { it.phase in setOf(SendIntentPhase.Preparing,SendIntentPhase.NeedsAttention,SendIntentPhase.Confirming) }<32) { "待发送消息过多" }
        check(statuses.count { !it.intent.sourcesReleased }<128 || adopting!=null) { "请先处理保留的待发送消息" }
        require(all().none { it.id==intent.id || it.operation==intent.operation } && command(intent.operation)==null)
        for(source in intent.attachments) {
            require(imports.all().none {it.id==source.id || it.request.targetMedia==source.id})
            require(resources.uploads().none { it.id==source.id || it.request.media==source.id || it.request.operation==source.id })
            val consumer=SendOriginalConsumer(intent.id,source.asset)
            resources.bindSend(source.asset,intent.room,consumer,adopting?.let { SendOriginalConsumer(it.id,source.asset) })
            val asset=resources.sendOriginal(consumer)
            require(asset.displayName==source.displayName && asset.contentType==source.contentType && asset.byteCount==source.byteCount)
            resources.prepare(source.id,source.asset,ResourceUploadRequest(source.id,source.id,ResourceUsage.Attachment(intent.room),asset.contentType,asset.byteCount,asset.checksum,
                modes=persistentListOf(ResourceTransferMode.PartPut,ResourceTransferMode.Put),displayName=asset.displayName,dimensions=asset.dimensions),send=consumer)
        }
        for(source in intent.serverImports) {
            require(resources.uploads().none {it.id==source.id || it.request.media==source.request.targetMedia})
            val work=imports.prepare(source.id,source.request,now)
            require(work.request==source.request && work.request.targetUsage==ResourceUsage.Attachment(intent.room))
            imports.bind(source.id,SendImportConsumer(intent.id,source.id))
        }
        statuses.filter { it.intent.sourcesReleased && it.phase!=SendIntentPhase.Confirming }.dropLast(127).forEach {
            db.execSQL("DELETE FROM send_intent_imports WHERE intent=?",arrayOf(it.intent.id));db.execSQL("DELETE FROM send_intent_attachments WHERE intent=?",arrayOf(it.intent.id));db.execSQL("DELETE FROM send_intents WHERE id=?",arrayOf(it.intent.id))
        }
        db.execSQL("INSERT INTO send_intents(id,operation,payload) VALUES (?,?,?)",arrayOf(intent.id,intent.operation,Json.encodeToString(intent)))
        intent.attachments.forEach { source -> db.execSQL("INSERT INTO send_intent_attachments VALUES (?,?,?)",arrayOf<Any>(intent.id,intent.attachmentOrder.indexOf(source.id),source.id)) }
        intent.serverImports.forEach { source -> db.execSQL("INSERT INTO send_intent_imports VALUES (?,?,?)",arrayOf<Any>(intent.id,intent.attachmentOrder.indexOf(source.id),source.id)) }
        return intent
    }
    private fun releaseSources(intent: SendIntent,committed: Boolean=false) {
        intent.attachments.forEach { resources.releaseSend(SendOriginalConsumer(intent.id,it.asset)) }
        intent.serverImports.forEach {imports.releaseConsumer(it.id,SendImportConsumer(intent.id,it.id),committed)}
        put(intent.copy(sourcesReleased=true))
    }
    fun reconcile() {
        statuses().filter { it.phase==SendIntentPhase.Accepted && !it.intent.sourcesReleased }.forEach { releaseSources(it.intent,committed=true) }
        val uploads=resources.uploads().associateBy { it.id }
        for(intent in all().filter { it.sourcesReleased }) for(source in intent.attachments) {
            val work=uploads[source.id] ?: continue
            if(work.sourceReleased) continue
            if(work.terminal) { if(work.execution.owner==null) resources.release(work.id) }
            else if(!work.cancellationRequested) resources.cancel(work.id)
        }
        releaseUnusedImports()
    }
    private fun releaseUnusedImports() {
        val jobs=imports.all().associateBy {it.id}
        for(intent in all().filter {it.sourcesReleased}) for(source in intent.serverImports) {
            val work=jobs[source.id] ?: continue
            val preserveReady=work.status?.state==ResourceImportState.Ready && !work.cancellationRequested && db.rawQuery("SELECT cancel_unfinished_only FROM send_intents WHERE id=?",arrayOf(intent.id)).use {it.moveToFirst() && it.getInt(0)==1}
            if(preserveReady) {if(work.execution.owner==null && !imports.hasConsumers(work.id)) imports.release(work.id)}
            else if(work.businessBound || work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed) || work.cancellationResolved) {
                if(work.terminal && work.execution.owner==null) imports.release(work.id)
            } else if(!work.cancellationRequested) imports.cancel(work.id)
        }
    }
    private fun failed(work: ResourceImportWork,now: Long)=work.businessBound || work.cancellationRequested ||
        work.status?.state in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed) ||
        work.status?.state==ResourceImportState.Ready && work.status?.bindable(now)!=true
    private fun failed(work: ResourceUploadWork,now: Long)=work.cancellationRequested || work.stage in setOf(ResourceUploadStage.Cancelled,ResourceUploadStage.Rejected,ResourceUploadStage.Expired) ||
        if(work.stage==ResourceUploadStage.Ready) work.session?.bindable(now)!=true else work.session?.expiresAt?.let { it<=now }==true
    fun advance(now: Long) {
        reconcile()
        // A slow transfer does not block other conversations or an independent ready message.
        val importedJobs=imports.all().associateBy {it.id}
        for(intent in all().filter { it.preparation in setOf(SendPreparation.Preparing,SendPreparation.NeedsAttention) }) {
            fun transition(next: SendPreparation) {if(intent.preparation!=next) put(intent.copy(preparation=next))}
            if(intent.deadline<=now) { transition(SendPreparation.Expired);continue }
            if(revoked(intent.room.value)) { transition(SendPreparation.NeedsAttention);continue }
            var waiting=false;var issue:SendPreparation?=null
            val uploads=resources.uploads().associateBy { it.id }
            for(source in intent.attachments) {
                val asset=try { resources.sendOriginal(SendOriginalConsumer(intent.id,source.asset)) } catch(_: NoSuchElementException) { null } catch(_: IllegalArgumentException) { null }
                val work=uploads[source.id]
                if(asset==null || work==null || work.sourceReleased || work.asset!=source.asset || work.request.usage!=ResourceUsage.Attachment(intent.room)) { issue=SendPreparation.Failed;break }
                if(failed(work,now)) { issue=if(work.stage==ResourceUploadStage.Ready) SendPreparation.Expired else SendPreparation.Failed;break }
                if(!work.terminal && (work.execution.attention || work.execution.userPaused)) { issue=SendPreparation.NeedsAttention;break }
                if(work.stage!=ResourceUploadStage.Ready || work.execution.owner!=null) waiting=true
            }
            if(issue==null) for(source in intent.serverImports) {
                val work=importedJobs[source.id]
                if(work==null || work.request!=source.request) {issue=SendPreparation.Failed;break}
                imports.requireConsumer(source.id,SendImportConsumer(intent.id,source.id))
                if(failed(work,now)) {issue=if(work.status?.state==ResourceImportState.Ready && !work.cancellationRequested && !work.businessBound) SendPreparation.Expired else SendPreparation.Failed;break}
                if(!work.terminal && (work.execution.attention || work.execution.paused)) {issue=SendPreparation.NeedsAttention;break}
                if(!work.bindable(now)) waiting=true
            }
            if(issue!=null) { transition(issue);continue }
            if(waiting) continue
            val deadline=Math.addExact(now,ClientSubmissionWindow.COMMAND_MILLISECONDS)
            val operation=if(intent.attachmentOrder.isEmpty()) MessageCommand.text(actor,intent.room,intent.text,deadline,intent.operation,intent.rich)
                else MessageCommand.withMedia(actor,intent.room,intent.text,intent.mediaIds,deadline,intent.operation,intent.rich)
            enqueueOutbox(operation)
            if (intent.id == intent.operation) db.execSQL("UPDATE outbox SET echo_created=? WHERE id=?", arrayOf<Any>(intent.createdAt, intent.operation))
            put(intent.copy(preparation=SendPreparation.HandedOff))
        }
    }
    fun deadline(): Long?=all().filter { it.preparation in setOf(SendPreparation.Preparing,SendPreparation.NeedsAttention) }.minOfOrNull { it.deadline }
    fun resume(id: String,now: Long): SendIntent? {
        val status=statuses().first { it.intent.id==id };val intent=status.intent
        require(!intent.sourcesReleased)
        if(intent.preparation==SendPreparation.HandedOff) { require(status.phase!=SendIntentPhase.Accepted);return if(status.phase==SendIntentPhase.Confirming) intent else null }
        if(intent.deadline<=now) { put(intent.copy(preparation=SendPreparation.Expired));return null }
        if(intent.preparation in setOf(SendPreparation.Cancelled,SendPreparation.Failed,SendPreparation.Expired)) return null
        check(!revoked(intent.room.value))
        for(source in intent.attachments) {
            val work=resources.uploads().first { it.id==source.id }
            if(failed(work,now) || work.sourceReleased) { put(intent.copy(preparation=SendPreparation.Failed));return null }
            if(!work.terminal && work.execution.owner==null && (work.execution.attention || work.execution.userPaused)) resources.control(work.id,false,work.execution.attention)
        }
        for(source in intent.serverImports) {
            val work=imports.all().first {it.id==source.id};require(work.request==source.request)
            imports.requireConsumer(source.id,SendImportConsumer(intent.id,source.id))
            if(failed(work,now)) {put(intent.copy(preparation=SendPreparation.Failed));return null}
            if(!work.terminal && work.execution.owner==null && (work.execution.attention || work.execution.paused)) imports.control(work.id,false,work.execution.attention)
        }
        return intent.copy(preparation=SendPreparation.Preparing).also(::put)
    }
    fun replace(id: String,next: SendIntent,now: Long): SendIntent {
        val old=statuses().first { it.intent.id==id };require(old.canReplace)
        require(next.room==old.intent.room && next.text==old.intent.text && next.rich==old.intent.rich && next.attachments.size==old.intent.attachments.size && next.serverImports.size==old.intent.serverImports.size)
        require(next.attachments.zip(old.intent.attachments).all { (fresh,original) -> fresh.copy(id=original.id)==original })
        require(next.serverImports.zip(old.intent.serverImports).all {(fresh,original)->
            fresh.id!=original.id && fresh.request.operation!=original.request.operation && fresh.request.targetMedia!=original.request.targetMedia &&
                fresh.request.source==original.request.source && fresh.request.targetUsage==original.request.targetUsage})
        val jobMap=(old.intent.attachments.zip(next.attachments).map {(a,b)->a.id to b.id}+old.intent.serverImports.zip(next.serverImports).map {(a,b)->a.id to b.id}).toMap()
        require(next.attachmentOrder==old.intent.attachmentOrder.map {jobMap.getValue(it)})
        enqueue(next,now,old.intent);discard(id);return next
    }
    /** The resource preview may span up to 64 parents; the current schema normally has one parent per job. */
    fun preparationCancellationParents(transfer:ResourceTransferId,includingReady:Boolean=false):PersistentList<SendIntent>? {
        if(transfer.kind==ResourceTransferKind.Download) return null
        val upload=transfer.kind==ResourceTransferKind.Upload
        if(upload) {
            val work=resources.upload(transfer.value) ?: return null
            if(work.cancellationRequested || work.request.usage !is ResourceUsage.Attachment || !includingReady && work.stage==ResourceUploadStage.Ready) return null
        } else {
            val work=imports.find(transfer.value) ?: return null
            if(work.cancellationRequested || work.businessBound || work.request.targetUsage !is ResourceUsage.Attachment || !includingReady && work.status?.state==ResourceImportState.Ready) return null
        }
        if(hasAvatarOwner(transfer)) return null
        val column=if(upload) "upload_id" else "import_id"
        val table=if(upload) "send_intent_attachments" else "send_intent_imports"
        val parents=db.rawQuery("SELECT i.payload FROM $table d JOIN send_intents i ON i.id=d.intent WHERE d.$column=? ORDER BY i.id LIMIT 65",arrayOf(transfer.value)).use {rows->buildList {
            while(rows.moveToNext()) add(Json.decodeFromString<SendIntent>(rows.getString(0)).also {require(it.actor==actor)})
        }}.filter {it.preparation!=SendPreparation.Cancelled}
        if(parents.isEmpty() || parents.size>64 || parents.any {it.sourcesReleased || it.preparation==SendPreparation.HandedOff || command(it.operation)!=null}) return null
        // Every target relation must agree with the frozen request and still own its original/import.
        for(parent in parents) if(upload) {
            val source=parent.attachments.singleOrNull {it.id==transfer.value} ?: return null
            val work=resources.upload(source.id) ?: return null
            if(work.asset!=source.asset || work.request.usage!=ResourceUsage.Attachment(parent.room)) return null
            if(!resources.ownsSendSource(SendOriginalConsumer(parent.id,source.asset))) return null
        } else {
            val source=parent.serverImports.singleOrNull {it.id==transfer.value} ?: return null
            if(imports.find(source.id)?.request!=source.request) return null
            if(!imports.hasConsumer(source.id,SendImportConsumer(parent.id,source.id))) return null
        }
        return parents.toPersistentList()
    }
    private fun hasAvatarOwner(transfer:ResourceTransferId):Boolean {
        val column=if(transfer.kind==ResourceTransferKind.Upload) "upload_id" else "import_id"
        return db.rawQuery("SELECT 1 FROM profile_intents WHERE $column=? UNION ALL SELECT 1 FROM group_avatar_intents WHERE $column=? LIMIT 1",arrayOf(transfer.value,transfer.value)).use {it.moveToFirst()}
    }
    private fun hasUnreleasedParent(transfer:ResourceTransferId):Boolean {
        val upload=transfer.kind==ResourceTransferKind.Upload
        val column=if(upload) "upload_id" else "import_id";val table=if(upload) "send_intent_attachments" else "send_intent_imports"
        return db.rawQuery("SELECT i.payload FROM $table d JOIN send_intents i ON i.id=d.intent WHERE d.$column=?",arrayOf(transfer.value)).use {rows->
            var found=false
            while(rows.moveToNext()) {val parent=Json.decodeFromString<SendIntent>(rows.getString(0));if(!parent.sourcesReleased && parent.preparation!=SendPreparation.Cancelled) found=true}
            found
        }
    }
    fun cancelPreparation(transfer:ResourceTransferId,reviewed:PersistentList<String>):ResourcePreparationCancellationResult {
        val parents=preparationCancellationParents(transfer,includingReady=true) ?: throw ResourceTransferActionUnavailable()
        if(parents.map {it.id}!=reviewed) throw ResourceTransferActionUnavailable()
        // Withdraw all parents before releasing any dependency. Any release error rolls the entire writer transaction back.
        for(parent in parents) {
            db.execSQL("UPDATE send_intents SET cancel_unfinished_only=1 WHERE id=?",arrayOf(parent.id))
            releaseSources(parent.copy(preparation=SendPreparation.Cancelled))
        }
        var uploads=0;var imported=0
        for(id in parents.flatMap {it.attachments}.map {it.id}.distinct()) {
            val key=ResourceTransferId(ResourceTransferKind.Upload,id);val work=resources.upload(id) ?: continue
            if(!work.terminal && !work.cancellationRequested && !hasUnreleasedParent(key) && !hasAvatarOwner(key)) {resources.cancel(id);uploads++}
        }
        for(id in parents.flatMap {it.serverImports}.map {it.id}.distinct()) {
            val key=ResourceTransferId(ResourceTransferKind.ServerImport,id);val work=imports.find(id) ?: continue
            if(!work.terminal && !work.cancellationRequested && !work.businessBound && !imports.hasConsumers(id) && !hasUnreleasedParent(key) && !hasAvatarOwner(key)) {imports.cancel(id);imported++}
        }
        return ResourcePreparationCancellationResult(parents.size,uploads,imported)
    }
    fun discard(id: String) {
        val status=statuses().first { it.intent.id==id };val intent=status.intent
        if(intent.sourcesReleased) return
        require(status.phase!=SendIntentPhase.Confirming) { "发送结果尚未确认，不能丢弃" }
        val cancelled=if(intent.preparation==SendPreparation.HandedOff) intent else intent.copy(preparation=SendPreparation.Cancelled)
        releaseSources(cancelled);reconcile()
    }
}
