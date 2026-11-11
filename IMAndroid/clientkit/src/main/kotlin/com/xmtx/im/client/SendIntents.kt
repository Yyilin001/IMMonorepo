package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import java.util.UUID

@Serializable data class SendAttachment(val id: String,val asset: String,val displayName: String,val contentType: String,val byteCount: Long) {
    init { require(uuidId(id)==id && uuidId(asset)==asset && resourceDisplayName(displayName)==displayName && byteCount>0);requireResourceContentType(contentType) }
}
@Serializable data class SendImportedAttachment(val id: String,val request: ResourceImportRequest) {
    init { require(uuidId(id)==id && request.targetUsage is ResourceUsage.Attachment) }
}
internal object SendImportsSerializer: ForwardListSerializer<SendImportedAttachment>(SendImportedAttachment.serializer())
internal object SendAttachmentOrderSerializer: ForwardListSerializer<String>(String.serializer())
internal object SendAttachmentsSerializer: ForwardListSerializer<SendAttachment>(SendAttachment.serializer())
@Serializable enum class SendPreparation { Preparing, NeedsAttention, Failed, Expired, Cancelled, HandedOff }
/** Frozen user intent; provider URIs, paths, credentials and mutable collections have no place here. */
@Serializable data class SendIntent(val id: String,val actor: UserId,val room: RoomId,val operation: String,val text: String,
    @Serializable(with=SendAttachmentsSerializer::class) val attachments: PersistentList<SendAttachment>,val createdAt: Long,val deadline: Long,
    val preparation: SendPreparation=SendPreparation.Preparing,val sourcesReleased: Boolean=false,val rich: MessageRichContent=MessageRichContent.Empty,
    @Serializable(with=SendImportsSerializer::class) val serverImports: PersistentList<SendImportedAttachment> = persistentListOf(),
    @Serializable(with=SendAttachmentOrderSerializer::class) val attachmentOrder: PersistentList<String> = (attachments.map {it.id}+serverImports.map {it.id}).toPersistentList(),
    val preparationStartedAt: Long = createdAt) {
    init {
        require(uuidId(id)==id && uuidId(operation)==operation);uuidId(actor.value);uuidId(room.value)
        rich.validate(text)
        require(createdAt>=0 && preparationStartedAt>=createdAt && deadline==Math.addExact(preparationStartedAt,86400000))
        require(text.toByteArray(Charsets.UTF_8).size<=65536 && (text.isNotBlank() || attachments.isNotEmpty() || serverImports.isNotEmpty()))
        val jobs=attachments.map {it.id}+serverImports.map {it.id}
        require(jobs.size<=10 && jobs.distinct().size==jobs.size && attachments.map {it.asset}.distinct().size==attachments.size)
        require(serverImports.all {it.request.targetUsage==ResourceUsage.Attachment(room)})
        require(serverImports.map {it.request.operation}.distinct().size==serverImports.size)
        val media=attachments.map {it.id}+serverImports.map {it.request.targetMedia}
        require(media.distinct().size==media.size)
        require(attachmentOrder.size==jobs.size && attachmentOrder.toSet()==jobs.toSet())
    }
    /** Job order is frozen independently of transfer kind; only target media enter the wire command. */
    val mediaIds: PersistentList<String> get() {
        val imported=serverImports.associate {it.id to it.request.targetMedia}
        return attachmentOrder.map {imported[it] ?: it}.toPersistentList()
    }
}
enum class SendIntentPhase { Preparing, NeedsAttention, Expired, Cancelled, Confirming, Accepted, Rejected, Closed }
data class SendIntentStatus(val intent: SendIntent,val phase: SendIntentPhase,val recovery: SendRecoveryStatus?=null) {
    val canResumeConfirmation get()=phase==SendIntentPhase.Confirming && recovery==SendRecoveryStatus.NeedsAttention
    val canReplace get()=!intent.sourcesReleased && phase in setOf(SendIntentPhase.NeedsAttention,SendIntentPhase.Expired,SendIntentPhase.Rejected,SendIntentPhase.Closed)
}
data class SendOriginalConsumer(val intent: String,val asset: String) {
    init { require(uuidId(intent)==intent && uuidId(asset)==asset) }
    val key get()="sendIntent/$intent/$asset"
}
data class SendImportConsumer(val intent: String,val job: String): ResourceImportConsumer {
    init {require(uuidId(intent)==intent && uuidId(job)==job)}
    override val key get()="sendIntent/$intent/import/$job"
}
interface SendIntentStore {
    val sendIntentChanges: StateFlow<Long>
    suspend fun sendIntents(): PersistentList<SendIntentStatus>
    suspend fun enqueueSendIntent(intent: SendIntent,now: Long): SendIntent
    suspend fun advanceSendIntents(now: Long): Boolean
    suspend fun sendPreparationDeadline(): Long?
    suspend fun resumeSendIntent(id: String,now: Long): SendIntent?
    suspend fun replaceSendIntent(id: String,next: SendIntent,now: Long): SendIntent
    suspend fun discardSendIntent(id: String)
}
/** Account-owned preparation: all dependencies and the outbox handoff are durable transactions. */
class SendIntentService(private val actor: UserId,private val store: SendIntentStore,private val now: ()->Long=System::currentTimeMillis) {
    /** Keep this value until local acceptance is known; retrying it cannot create another send. */
    fun prepare(room: RoomId,text: String,attachments: PersistentList<SendAttachment>,rich: MessageRichContent=MessageRichContent.Empty,
        serverImports: PersistentList<SendImportedAttachment> = persistentListOf(),
        attachmentOrder: PersistentList<String> = (attachments.map {it.id}+serverImports.map {it.id}).toPersistentList()): SendIntent {
        val time=now();return SendIntent(id(),actor,room,id(),text,attachments,time,Math.addExact(time,86400000),rich=rich,serverImports=serverImports,attachmentOrder=attachmentOrder)
    }
    fun prepareDraft(draft: ConversationDraft)=prepare(draft.room,draft.sendText,draft.attachments,draft.rich,draft.sendImports,draft.attachmentOrder)
    suspend fun enqueue(intent: SendIntent): SendIntent { require(intent.actor==actor);return store.enqueueSendIntent(intent,now()) }
    suspend fun enqueue(room: RoomId,text: String,attachments: PersistentList<SendAttachment>,rich: MessageRichContent=MessageRichContent.Empty)=enqueue(prepare(room,text,attachments,rich))
    suspend fun resumeOrReapply(id: String): SendIntent {
        store.resumeSendIntent(id,now())?.let { return it }
        val old=store.sendIntents().first { it.intent.id==id };require(old.intent.actor==actor && old.canReplace)
        val time=now();val jobs=old.intent.attachmentOrder.associateWith {id()}
        val next=old.intent.copy(id=id(),operation=id(),attachments=old.intent.attachments.map {it.copy(id=jobs.getValue(it.id))}.toPersistentList(),
            serverImports=old.intent.serverImports.map {it.copy(id=jobs.getValue(it.id),request=it.request.copy(operation=id(),targetMedia=id()))}.toPersistentList(),
            attachmentOrder=old.intent.attachmentOrder.map {jobs.getValue(it)}.toPersistentList(),
            createdAt=time,preparationStartedAt=time,deadline=Math.addExact(time,86400000),preparation=SendPreparation.Preparing,sourcesReleased=false)
        return store.replaceSendIntent(id,next,time)
    }
    suspend fun discard(id: String)=store.discardSendIntent(id)
    suspend fun prepareNext()=store.advanceSendIntents(now())
    suspend fun runPreparation(): Unit=coroutineScope {
        val wake=Channel<Unit>(Channel.CONFLATED)
        val observer=launch { store.sendIntentChanges.collect { wake.trySend(Unit) } }
        try { while(isActive) {
            if(prepareNext()) continue
            val deadline=store.sendPreparationDeadline()
            if(deadline==null) wake.receive() else withTimeoutOrNull((deadline-now()).coerceIn(1,60000)) { wake.receive() }
        } } finally { observer.cancel();wake.close() }
    }
    private fun id()=UUID.randomUUID().toString().uppercase()
}
