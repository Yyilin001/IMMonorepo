package com.xmtx.im

import android.content.Context
import android.net.Uri
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest

/** Explicit account lifetime. Route replacement waits for the previous editor's local writes to drain. */
internal class ChatComposerRepository(context: Context,actor: UserId,private val store: SqliteClientStore,private val files: ManagedResourceFiles,
    private val lookupMention: suspend (String)->UserId={error("身份目录暂不可用")},private val readProfiles: ProfilePresentationReading?=null,private val publishImage: (DraftImageState?)->Unit={},private val publish: (ChatComposerState?)->Unit) {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private data class Destination(val room: RoomId,val asset: String?,val generation: Long)
    private var routeGeneration=0L;private var activeDestination: Destination?=null
    private val route=MutableStateFlow<Destination?>(null);private var foreground=false;private var closed=false
    private var controller: ChatComposerController?=null;private var imageController: DraftImageController?=null
    private val sends=SendIntentService(actor,store);private val processor=PhotoPreparation();private val previewProcessor=MessageImagePreparation()
    private val drafts=object: ConversationDraftStore by store {
        override suspend fun conversationDraft(room: RoomId): ConversationDraft { files.selected(ResourceUsage.Attachment(room));return store.conversationDraft(room) }
    }
    private val observer=scope.launch {
        route.collectLatest { destination ->
            if(destination==null || closed) return@collectLatest
            activeDestination=destination
            val room=destination.room
            if(destination.asset!=null) {
                val selection=DraftImageSelection(room,destination.asset)
                val viewer=DraftImageController(selection,scope,store.resourceDirectoryChanges,
                    resolve={
                        val selected=files.selected(ResourceUsage.Attachment(room))
                        val attachment=store.conversationDraft(room).attachments.firstOrNull { it.asset==selection.asset && it.contentType.startsWith("image/") }
                        attachment?.takeIf { value -> selected.any { it.id==value.asset && it.availability==ResourceAssetAvailability.Local && it.displayName==value.displayName && it.contentType==value.contentType && it.byteCount==value.byteCount } }
                    },read={ attachment -> files.withOriginal(selection=attachment.asset) { previewProcessor.prepare(it) } },
                    publish={ value -> if(!closed && route.value==destination && imageController?.selection==selection) publishImage(value) })
                imageController=viewer;viewer.foreground(foreground)
                try { awaitCancellation() }
                finally { activeDestination=null;imageController=null;withContext(NonCancellable) { viewer.close() };if(!closed) publishImage(null) }
                return@collectLatest
            }
            var nextKindRead:Long?=null
            val editor=ChatComposerController(room,scope,drafts,
                prepareSend={ text,attachments -> sends.prepare(room,text,attachments) },
                stage={ uri ->
                    val photo=processor.prepare(context.contentResolver,uri)
                    val asset=files.importPhoto(photo,ResourceUsage.Attachment(room))
                    SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount)
                },stageDocument={ uri ->
                    val asset=files.importDocument(context.contentResolver,uri,ResourceUsage.Attachment(room))
                    SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount)
                },thumbnail={ attachment ->
                    val asset=files.selected(ResourceUsage.Attachment(room)).first { it.id==attachment.asset }
                    require(asset.displayName==attachment.displayName && asset.contentType==attachment.contentType && asset.byteCount==attachment.byteCount)
                    files.withOriginal(selection=asset.id) { previewProcessor.thumbnail(it) }
                },createCamera={ CameraCaptureFiles.create(context) },release={ asset -> files.discardSelection(asset);files.cleanup() },
                missing={ draft ->
                    val available=files.selected(ResourceUsage.Attachment(room)).filter { it.availability==ResourceAssetAvailability.Local }.map { it.id }.toSet()
                    (draft.attachments.filter { it.asset !in available }.map { it.asset }+
                        draft.imports.filterNot {store.isConversationResourceCurrent(it.selection)}.map {it.id}).toPersistentSet()
                },resolveMentions={ input->resolveChatMentions(input,store.appSnapshot().conversations.any {it.id==room && it.kind==RoomKind.Group},lookupMention) },
                readSendingPolicy={
                    val local=store.conversationSendingPolicy(room,actor)
                    val peer=if(local.accountKind==null && readProfiles!=null) store.directSendingPeer(room,actor) else null
                    if(peer!=null && (nextKindRead==null || System.nanoTime()-nextKindRead!!>=0)) {
                        nextKindRead=System.nanoTime()+5_000_000_000L
                        val key=ProfileKey(peer,ProfileContext.DirectConversation);val keys=persistentListOf(key)
                        val before=store.profileFences(keys)
                        val result=readProfiles!!.read(keys).singleOrNull {it.key==key}
                        currentCoroutineContext().ensureActive()
                        if(!closed && foreground && route.value==destination && result is ProfileReadResult.Available) store.adoptDirectAccountKind(room,result,before)
                    }
                    store.conversationSendingPolicy(room,actor)
                },validateReply={id->store.messageSource(room,actor,id)!=null},importDrafts=store,prepareDraft=sends::prepareDraft,publish={ value -> if(!closed && route.value==destination && controller?.id==value.id) publish(value) })
            controller=editor;editor.foreground(foreground)
            try { awaitCancellation() }
            finally { activeDestination=null;controller=null;withContext(NonCancellable) { editor.close() };if(!closed) publish(null) }
        }
    }
    fun activate(room: RoomId?,asset: String?=null) {
        if(closed || route.value?.room==room && route.value?.asset==asset) return
        routeGeneration++
        publish(null);publishImage(null)
        route.value=room?.let { Destination(it,asset,routeGeneration) }
    }
    fun refreshSendingCapability() {if(!closed) controller?.refreshSendingCapability()}
    fun foreground(value: Boolean) { foreground=value;controller?.foreground(value);imageController?.foreground(value) }
    private fun editor(id: String)=controller?.takeIf { !closed && it.id==id && route.value==activeDestination && it.room==route.value?.room && route.value?.asset==null }
    fun editContent(id: String,text: String,rich: MessageRichContent) {editor(id)?.editContent(text,rich)}
    fun mentions(id: String,input: String) {editor(id)?.mentions(input)}
    fun reply(id: String,message: Message?) {editor(id)?.reply(message)}
    fun edit(id: String,text: String) { editor(id)?.edit(text) }
    fun beginPick(id: String)=editor(id)?.beginPick()==true
    fun picked(id: String,uri: Uri?) { editor(id)?.picked(uri) }
    fun pickedPhotos(id: String,uris: List<Uri>) { editor(id)?.pickedPhotos(uris) }
    fun beginDocument(id: String)=editor(id)?.beginPick(ChatAttachmentSource.Document)==true
    fun documentPicked(id: String,uri: Uri?) { editor(id)?.picked(uri,ChatAttachmentSource.Document) }
    fun takePicture(id: String,launch: (Uri)->Unit) { editor(id)?.takePicture(launch) }
    fun captured(id: String,success: Boolean) { editor(id)?.captured(success) }
    fun pickerFailed(id: String) { editor(id)?.pickerFailed() }
    fun remove(id: String,asset: String) { editor(id)?.remove(asset) }
    fun move(id: String,asset: String,offset: Int) { editor(id)?.move(asset,offset) }
    fun retryImage(selection: DraftImageSelection) { imageController?.takeIf { it.selection==selection && route.value==activeDestination }?.retry() }
    suspend fun addImported(id: String,selection: MessageAttachmentSelection) {requireNotNull(editor(id)).addImported(selection)}
    fun send(id: String) { editor(id)?.send() }
    fun retry(id: String) { editor(id)?.retrySave() }
    suspend fun close()=withContext(NonCancellable) { if(!closed) { closed=true;observer.cancelAndJoin();scope.cancel() } }
}
