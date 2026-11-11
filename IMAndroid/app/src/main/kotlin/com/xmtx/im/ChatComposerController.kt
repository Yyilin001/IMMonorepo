package com.xmtx.im

import android.net.Uri
import com.xmtx.im.client.*
import com.xmtx.im.platform.CameraPhoto
import com.xmtx.im.platform.NormalizedPhoto
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

enum class ChatAttachmentSource { Photo, Document, Camera }

data class DraftAttachmentRow(val id: String,val asset: String,val displayName: String,val contentType: String,val byteCount: Long,val imported: Boolean=false)

data class AttachmentPreparationProgress(val completed: Int,val total: Int)

data class ChatComposerState(val id: String,val room: RoomId,val draft: ConversationDraft?=null,val text: String="",
    val available: Boolean=false,val loading: Boolean=true,val saving: Boolean=false,val preparing: Boolean=false,val source: ChatAttachmentSource?=null,
    val canSend: Boolean?=null,val directAccountKind: AccountKind?=null,val capabilityFeedback: String?=null,val sending: Boolean=false,val feedback: String?=null,val unavailable: PersistentSet<String> = persistentSetOf(),
    val progress: AttachmentPreparationProgress?=null,val thumbnails: PersistentMap<String,NormalizedPhoto> = persistentMapOf(),
    val thumbnailFailures: PersistentSet<String> = persistentSetOf(),val rich: MessageRichContent=MessageRichContent.Empty,val resolvingMentions: Boolean=false,val contentLocked: Boolean=false) {
    val sendingPolicy get()=ConversationSendingPolicy(canSend,directAccountKind)
    val picking get()=source!=null
    val attachments get()=draft?.attachments ?: persistentListOf()
    val resources: PersistentList<DraftAttachmentRow> get() {
        val value=draft ?: return persistentListOf()
        val rows=attachments.associate {it.id to DraftAttachmentRow(it.id,it.asset,it.displayName,it.contentType,it.byteCount)}+
            value.imports.associate {it.id to DraftAttachmentRow(it.id,it.id,it.selection.descriptor.displayName,it.selection.descriptor.contentType,it.selection.descriptor.byteCount,true)}
        return value.attachmentOrder.map {rows.getValue(it)}.toPersistentList()
    }
}
/** Account-owned local writes survive route changes; close drains them before SQLite or files can close. */
internal class ChatComposerController(val room: RoomId,parent: CoroutineScope,private val store: ConversationDraftStore,
    private val prepareSend: (String,PersistentList<SendAttachment>)->SendIntent,
    private val stage: suspend (Uri)->SendAttachment,private val release: suspend (String)->Unit,
    private val missing: suspend (ConversationDraft)->PersistentSet<String>,private val publish: (ChatComposerState)->Unit,
    private val now: ()->Long=System::currentTimeMillis,
    private val stageDocument: suspend (Uri)->SendAttachment={ error("文件选择不可用") },
    private val createCamera: suspend ()->CameraPhoto={ error("相机不可用") },
    private val thumbnail: suspend (SendAttachment)->NormalizedPhoto?={ null },
    private val resolveMentions: suspend (String)->PersistentList<MentionTarget> = { error("提及不可用") },
    private val validateReply: suspend (MessageId)->Boolean={true},
    private val importDrafts: ConversationImportDraftStore?=null,private val prepareDraft: ((ConversationDraft)->SendIntent)?=null,
    private val readSendingPolicy: suspend ()->ConversationSendingPolicy={ConversationSendingPolicy()}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    val id=UUID.randomUUID().toString().uppercase()
    var state=ChatComposerState(id,room);private set
    private val lock=Mutex();private var persisted: ConversationDraft?=null
    private var foreground=false;private var closing=false;private var closed=false;private var edits=0L
    private data class PendingAttachments(val source: ChatAttachmentSource,val uris: PersistentList<Uri>,val limited: Boolean=false)
    private var pendingUri: PendingAttachments?=null;private var attachmentJob: Job?=null;private var writer: Job?=null
    private var camera: CameraPhoto?=null;private var cameraReturned=false
    private var pendingSend: Pair<ConversationDraft,SendIntent>?=null
    private var previewJob: Job?=null;private var previewGeneration=0L
    private var mentionJob: Job?=null;private var mentionEpoch=0L
    private var capabilityJob: Job?=null;private var capabilityEpoch=0L
    private var sendEdit=0L
    private val finished=CompletableDeferred<Unit>()
    private fun update(body: (ChatComposerState)->ChatComposerState) { if(!closed) { state=body(state);if(!closing) publish(state) } }
    private val initial=scope.launch {
        lock.withLock {
            try { persisted=store.conversationDraft(room);val unavailable=missing(persisted!!);update { it.copy(draft=persisted,text=persisted!!.text,rich=persisted!!.rich,loading=false,unavailable=unavailable) };refreshThumbnails() }
            catch(error: CancellationException) { throw error }
            catch(_: Exception) { update { it.copy(loading=false,feedback="无法恢复草稿，请重新进入会话") } }
        }
    }
    fun foreground(value: Boolean) {
        if(closing || closed || foreground==value) return
        foreground=value;update { it.copy(available=value) }
        if(!value) {
            capabilityEpoch++;capabilityJob?.cancel()
            mentionEpoch++;mentionJob?.cancel();update {it.copy(resolvingMentions=false)}
            attachmentJob?.cancel();pendingUri=null;if(cameraReturned) releaseCamera()
            previewGeneration++;previewJob?.cancel();update { it.copy(thumbnails=persistentMapOf(),thumbnailFailures=persistentSetOf()) }
        } else { refreshSendingCapability();readPending();refreshThumbnails() }
    }
    fun refreshSendingCapability() {
        if(!foreground || closing || closed) return
        val epoch=++capabilityEpoch;capabilityJob?.cancel()
        capabilityJob=scope.launch {
            try {
                val policy=readSendingPolicy();currentCoroutineContext().ensureActive()
                if(foreground && !closing && epoch==capabilityEpoch) {
                    update {it.copy(canSend=policy.canSend,directAccountKind=policy.accountKind,capabilityFeedback=null)}
                    if(!policy.allowsNewContent) {
                        pendingUri=null;attachmentJob?.cancel();if(cameraReturned) releaseCamera()
                    }
                }
            } catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(foreground && !closing && epoch==capabilityEpoch) update {it.copy(capabilityFeedback="无法更新发送权限，请稍后重试。")}}
        }
    }
    fun edit(text: String) {
        if(!foreground || closing || !state.sendingPolicy.allowsNewContent || persisted==null || text.toByteArray(Charsets.UTF_8).size>32768) return
        if(state.text==text) return
        val rich=try {rebaseRichContent(state.text,text,state.rich)} catch(_:Exception) {update {it.copy(feedback="文字范围无效")};return}
        edits++;update { it.copy(text=text,rich=rich) };scheduleSave()
    }
    fun editContent(text: String,rich: MessageRichContent) {
        if(!foreground || closing || !state.sendingPolicy.allowsNewContent || persisted==null || pendingSend!=null || state.sending || text.toByteArray(Charsets.UTF_8).size>32768) return
        try {rich.validate(text)} catch(_:Exception) {update {it.copy(feedback="格式范围无效，请重新选择文字")};return}
        if(state.text==text && state.rich==rich) return
        edits++;update {it.copy(text=text,rich=rich,feedback=null)};scheduleSave()
    }
    fun reply(message: Message?) {
        if(message!=null && (message.roomId!=room || message.withdrawn || message.redacted || message.delivery!=Delivery.Accepted)) return
        editContent(state.text,state.rich.copy(replyTo=message?.id))
    }
    fun mentions(input: String) {
        if(!foreground || closing || !state.sendingPolicy.allowsNewContent || persisted==null || pendingSend!=null || state.sending) return
        val epoch=++mentionEpoch;val revision=edits;mentionJob?.cancel();update {it.copy(resolvingMentions=true,feedback=null)}
        mentionJob=scope.launch {
            try {
                val targets=resolveMentions(input);currentCoroutineContext().ensureActive()
                if(!closing && foreground && epoch==mentionEpoch) {
                    if(revision==edits) editContent(state.text,state.rich.copy(mentions=targets))
                    else update {it.copy(feedback="草稿已变化，请重新应用提及")}
                }
            } catch(error: CancellationException) {throw error}
            catch(error:Exception) {if(!closing && foreground && epoch==mentionEpoch) update {it.copy(feedback=error.message ?: "无法解析提及对象")}}
            finally {if(epoch==mentionEpoch) update {it.copy(resolvingMentions=false)}}
        }
    }
    private fun scheduleSave() {
        if(closed || closing || writer?.isActive==true || pendingSend!=null) return
        writer=scope.launch {
            lock.withLock {
                try { flushText() }
                catch(error: CancellationException) { throw error }
                catch(_: Exception) { update { it.copy(feedback="草稿暂未保存，请重试") } }
            }
        }
    }
    private suspend fun flushText() {
        if(pendingSend!=null) return
        update { it.copy(saving=true) }
        try {
            while(persisted!=null && (persisted!!.text!=state.text || persisted!!.rich!=state.rich)) {
                val text=state.text;val rich=state.rich
                persisted=store.saveConversationContent(persisted!!,text,rich,now())
                update { it.copy(draft=persisted,feedback=null) }
            }
        } finally { update { it.copy(saving=false) } }
    }
    private fun canPick()=foreground && !closing && state.sendingPolicy.allowsNewContent && persisted!=null && !state.preparing && !state.picking && !state.sending && state.resources.size<10 && pendingSend==null
    fun beginPick(source: ChatAttachmentSource=ChatAttachmentSource.Photo): Boolean {
        if(source==ChatAttachmentSource.Camera || !canPick()) return false
        update { it.copy(source=source,feedback=null) };return true
    }
    fun picked(uri: Uri?,source: ChatAttachmentSource=ChatAttachmentSource.Photo)=pickedMany(listOfNotNull(uri),source)
    fun pickedPhotos(uris: List<Uri>)=pickedMany(uris,ChatAttachmentSource.Photo)
    private fun pickedMany(uris: List<Uri>,source: ChatAttachmentSource) {
        if(closing || closed || state.source!=source || source==ChatAttachmentSource.Camera) return
        val limit=(10-state.resources.size).coerceAtLeast(0)
        val selected=uris.asSequence().distinct().take(limit+1).toList();val accepted=selected.take(limit).toPersistentList()
        update { it.copy(source=null) }
        pendingUri=accepted.takeIf { it.isNotEmpty() && state.sendingPolicy.allowsNewContent }?.let { PendingAttachments(source,it,selected.size>limit) };readPending()
    }
    fun pickerFailed() { if(!closed && state.source!=ChatAttachmentSource.Camera) { pendingUri=null;update { it.copy(source=null,feedback="无法打开系统选择器，请重试") } } }
    fun takePicture(launch: (Uri)->Unit) {
        if(!canPick()) return
        update { it.copy(preparing=true,feedback=null) }
        attachmentJob=scope.launch {
            var created: CameraPhoto?=null
            try {
                withContext(NonCancellable) { created=createCamera() };currentCoroutineContext().ensureActive()
                camera=created;created=null;cameraReturned=false
                update { it.copy(source=ChatAttachmentSource.Camera) }
                try { launch(requireNotNull(camera).uri) }
                catch(_: Exception) { releaseCamera();update { it.copy(source=null,feedback="无法打开系统相机，请检查相机应用") } }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { update { it.copy(source=null,feedback="无法准备拍照，请检查设备空间后重试") } }
            finally { created?.close();update { it.copy(preparing=false) };readPending() }
        }
    }
    fun captured(success: Boolean) {
        if(closing || closed || state.source!=ChatAttachmentSource.Camera || camera==null) return
        update { it.copy(source=null) }
        if(!success || !state.sendingPolicy.allowsNewContent) releaseCamera() else { cameraReturned=true;readPending() }
    }
    private fun releaseCamera() { val value=camera;camera=null;cameraReturned=false;value?.close() }
    private fun readPending() {
        if(!foreground || closing || closed || !state.sendingPolicy.allowsNewContent || state.preparing || state.picking) return
        val capture=if(cameraReturned) camera else null
        val pending=if(capture!=null) PendingAttachments(ChatAttachmentSource.Camera,persistentListOf(capture.uri)) else pendingUri ?: return
        if(capture!=null) { camera=null;cameraReturned=false }
        pendingUri=null;update { it.copy(preparing=true,feedback=null,progress=AttachmentPreparationProgress(0,pending.uris.size)) }
        attachmentJob=scope.launch(start=CoroutineStart.UNDISPATCHED) {
            var adoptedCount=0;var failures=0;var completed=0;var cleanupFailed=false
            try {
                for(uri in pending.uris) {
                    var attachment: SendAttachment?=null;var adopted=false
                    try {
                        attachment=if(pending.source==ChatAttachmentSource.Document) stageDocument(uri) else stage(uri)
                        currentCoroutineContext().ensureActive()
                        lock.withLock {
                            check(state.sendingPolicy.allowsNewContent)
                            withContext(NonCancellable) {
                                persisted=store.addConversationAttachment(room,attachment!!,now());adopted=true;adoptedCount++
                                update { it.copy(draft=persisted) }
                                val unavailable=missing(persisted!!);update { it.copy(unavailable=unavailable) };refreshThumbnails()
                            }
                        }
                    } catch(error: CancellationException) { throw error }
                    catch(_: Exception) { failures++ }
                    finally {
                        if(!adopted) attachment?.let { withContext(NonCancellable) { try { release(it.asset) } catch(_: Exception) { cleanupFailed=true } } }
                    }
                    completed++;update { it.copy(progress=AttachmentPreparationProgress(completed,pending.uris.size)) }
                }
            } finally {
                capture?.close()
                update { it.copy(preparing=false,progress=null,feedback=when {
                    cleanupFailed -> "部分附件未能清理，请重新进入会话检查草稿"
                    completed<pending.uris.size -> "附件读取已停止，已保留 $adoptedCount 项"
                    failures>0 -> "已添加 $adoptedCount 项，$failures 项未能添加，请重新选择"
                    pending.limited -> "每条消息最多 10 个附件，已添加剩余可用数量"
                    else -> it.feedback
                }) }
            }
        }
    }
    private fun refreshThumbnails() {
        val allowed=state.attachments.filter { it.contentType.startsWith("image/") && it.asset !in state.unavailable }.map { it.asset }.toSet()
        update { it.copy(thumbnails=it.thumbnails.filterKeys { key -> key in allowed }.toPersistentMap(),thumbnailFailures=it.thumbnailFailures.filter { key -> key in allowed }.toPersistentSet()) }
        if(!foreground || closing || previewJob!=null) return
        val next=state.attachments.firstOrNull { it.asset in allowed && it.asset !in state.thumbnails && it.asset !in state.thumbnailFailures } ?: return
        val generation=previewGeneration
        val job=scope.launch(start=CoroutineStart.LAZY) {
            try {
                val image=thumbnail(next);currentCoroutineContext().ensureActive()
                if(foreground && !closing && generation==previewGeneration && next in state.attachments && next.asset !in state.unavailable) {
                    if(image!=null && image.dimensions.width<=256 && image.dimensions.height<=256 && image.byteCount<=512*1024) update { it.copy(thumbnails=it.thumbnails.put(next.asset,image)) }
                    else update { it.copy(thumbnailFailures=it.thumbnailFailures.add(next.asset)) }
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(foreground && !closing && generation==previewGeneration && next in state.attachments) update { it.copy(thumbnailFailures=it.thumbnailFailures.add(next.asset)) } }
            finally { previewJob=null;refreshThumbnails() }
        }
        previewJob=job;job.start()
    }
    suspend fun addImported(selection: MessageAttachmentSelection) {
        check(canPick());val imports=requireNotNull(importDrafts)
        val prepared=ConversationResourceSelectionService(imports).prepare(room,selection)
        lock.withLock {
            check(canPick());flushText()
            withContext(NonCancellable) {
                persisted=imports.addConversationImport(requireNotNull(persisted),prepared,now())
                update {it.copy(draft=persisted)}
                val unavailable=missing(persisted!!)
                update {it.copy(draft=persisted,unavailable=unavailable,feedback="已添加聊天附件")}
            }
        }
    }
    fun remove(asset: String) {
        if(!foreground || closing || state.sending || state.preparing || pendingSend!=null) return
        scope.launch { lock.withLock {
            try {
                val saved=persisted ?: return@withLock
                val imported=saved.imports.any {it.id==asset}
                persisted=if(imported) requireNotNull(importDrafts).removeConversationImport(saved,asset,now()) else store.removeConversationAttachment(saved,asset,now())
                update { it.copy(draft=persisted,unavailable=it.unavailable.remove(asset),feedback=null) }
                refreshThumbnails();if(!imported) release(asset)
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { update { it.copy(feedback="未能移除附件，请重试") } }
        } }
    }
    fun move(asset: String,offset: Int) {
        if(!foreground || closing || state.sending || state.preparing || state.picking || pendingSend!=null || offset !in setOf(-1,1)) return
        scope.launch { lock.withLock {
            try {
                val saved=persisted ?: return@withLock
                val job=saved.attachments.firstOrNull {it.asset==asset}?.id ?: asset
                val index=saved.attachmentOrder.indexOf(job);val target=index+offset
                if(index<0 || target !in saved.attachmentOrder.indices) return@withLock
                val order=saved.attachmentOrder.removeAt(index).add(target,job)
                persisted=if(importDrafts!=null) importDrafts.reorderConversationResources(saved,order,now())
                    else store.reorderConversationAttachments(saved,order.map {id->saved.attachments.first {it.id==id}.asset}.toPersistentList(),now())
                update { it.copy(draft=persisted,feedback=null) }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { update { it.copy(feedback="未能调整附件顺序，请重新进入会话后重试") } }
        } }
    }
    fun send() {
        if(!foreground || closing || persisted==null || state.sending || state.preparing || state.picking || state.resolvingMentions) return
        if(pendingSend==null && !state.sendingPolicy.allowsNewContent) {update {it.copy(feedback=state.sendingPolicy.restriction)};return}
        val submittedText=state.text;val submittedRich=state.rich;val submittedEdit=edits
        if(pendingSend==null && submittedText.isBlank() && state.resources.isEmpty()) return
        update { it.copy(sending=true,contentLocked=true,feedback=null) }
        scope.launch {
            lock.withLock {
                try {
                    if(pendingSend==null) {
                        if(submittedRich.replyTo?.let {validateReply(it)}==false) {
                            update {it.copy(feedback="回复的消息当前不可用，请取消回复后重试")};return@withLock
                        }
                        persisted=store.saveConversationContent(persisted!!,submittedText,submittedRich,now())
                        val frozen=prepareDraft?.invoke(persisted!!) ?: prepareSend(persisted!!.sendText,persisted!!.attachments).copy(rich=persisted!!.rich)
                        pendingSend=persisted!! to frozen;sendEdit=submittedEdit
                    }
                    val (expected,intent)=pendingSend!!
                    try { store.submitConversationDraft(expected,intent,now()) }
                    catch(error: ConversationDraftSubmissionRejected) {
                        pendingSend=null
                        val unavailable=missing(expected)
                        update { it.copy(unavailable=unavailable,feedback=error.message ?: "消息未保存，请调整草稿后重试") }
                        return@withLock
                    }
                    // Read the persisted next draft; a repeated submission never clears a newer revision.
                    persisted=store.conversationDraft(room)
                    val text=if(edits==sendEdit) persisted!!.text else state.text
                    pendingSend=null
                    update { it.copy(draft=persisted,text=text,rich=persisted!!.rich,unavailable=persistentSetOf(),feedback="消息已保存，正在发送") };refreshThumbnails()
                    flushText()
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { update { it.copy(feedback="消息暂未确认保存，请重试；原草稿仍保留") } }
                finally { update { it.copy(sending=false,contentLocked=pendingSend!=null) } }
            }
        }
    }
    fun retrySave() { if(pendingSend!=null) send() else scheduleSave() }
    suspend fun close() {
        if(closing) { finished.await();return }
        closing=true;foreground=false;capabilityEpoch++;capabilityJob?.cancelAndJoin();mentionEpoch++;mentionJob?.cancelAndJoin();previewGeneration++;previewJob?.cancelAndJoin();pendingUri=null;attachmentJob?.cancelAndJoin();releaseCamera()
        try {
            initial.join()
            // Local send/save tasks are allowed to finish; a cancelled page cannot erase their result.
            lock.withLock { try { flushText() } catch(_: Exception) { } }
            scope.coroutineContext.job.children.toList().forEach { it.join() }
        } finally { closed=true;scope.cancel();finished.complete(Unit) }
    }
}
