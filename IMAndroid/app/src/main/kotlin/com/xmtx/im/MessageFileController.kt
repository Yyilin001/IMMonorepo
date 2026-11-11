package com.xmtx.im

import android.net.Uri
import com.xmtx.im.client.*
import com.xmtx.im.platform.TemporaryResourceLease
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

data class MessageFileSelection(val location: MediaMessageLocation,val media: String) {
    val key=ResourceKey(ResourceHome.Room(location.room),media)
}
enum class TemporaryFileMode { Open,Share }
data class TemporaryFileAction(val id: String,val uri: String,val contentType: String,val mode: TemporaryFileMode)
enum class FileSavePhase { Idle,Choosing,Waiting,Writing,Saved }
data class MessageFileState(val selection: MessageFileSelection,val available: Boolean=false,val read: MessageResourceRead?=null,
    val phase: FileSavePhase=FileSavePhase.Idle,val savedUri: String?=null,val feedback: String?=null,val opening: Boolean=false,val action: TemporaryFileAction?=null)
internal data class FileSaveRequest(val id: String,val read: MessageResourceRead)

/** Route-owned export. Picker results carry a unique request identity, never a durable permission. */
internal class MessageFileController(val selection: MessageFileSelection,parent: CoroutineScope,private val changes: Flow<Long>,
    private val resolve: suspend ()->MessageResourceRead,private val save: suspend (FileSaveRequest,Uri)->Unit,
    private val discard: suspend (Uri)->Boolean,private val publish: (MessageFileState)->Unit,
    private val prepare: (suspend (FileSaveRequest)->TemporaryResourceLease)?=null) {
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val foreground=MutableStateFlow(false)
    private var closed=false;private var epoch=0L;private var observer:Job?=null;private var writing:Job?=null
    private var pending:FileSaveRequest?=null
    private var presentation:Job?=null;private var presentationRequest:FileSaveRequest?=null
    private var launchMode=TemporaryFileMode.Open;private var claimed=false;private var launched=false
    private var returned:CompletableDeferred<Unit>?=null
    var state=MessageFileState(selection);private set
    private fun update(block: (MessageFileState)->MessageFileState) { if(!closed) { state=block(state);publish(state) } }
    private fun matches(read: MessageResourceRead)=read.descriptor.key==selection.key && read.source.room==selection.location.room && read.source.message==selection.location.message
    private suspend fun current(): MessageResourceRead=resolve().also { currentCoroutineContext().ensureActive();check(matches(it)) }
    fun foreground(value: Boolean) {
        if(closed || foreground.value==value) return
        foreground.value=value;val generation=++epoch;observer?.cancel();update { it.copy(available=false) }
        if(!value) {
            if(state.phase==FileSavePhase.Writing) writing?.cancel()
            if(!launched) presentation?.cancel()
            return
        }
        observer=scope.launch { changes.collectLatest {
            try {
                val read=current()
                if(!closed && foreground.value && epoch==generation) {
                    if(pending?.read!=null && pending?.read!=read) { pending=null;writing?.cancel();update { it.copy(phase=FileSavePhase.Idle,feedback="文件来源已变化，请重新选择保存位置") } }
                    if(presentationRequest?.read!=null && presentationRequest?.read!=read) presentation?.cancel()
                    update { it.copy(read=read,available=true) }
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(!closed && epoch==generation) {
                pending=null;writing?.cancel();presentation?.cancel();update { it.copy(available=false,read=null,phase=FileSavePhase.Idle,feedback="文件来源当前不可访问，请重试") }
            } }
        } }
    }
    fun begin(): String? {
        if(closed || !foreground.value || !state.available || pending!=null || writing?.isCompleted==false || presentation?.isCompleted==false) return null
        val read=state.read ?: return null
        val request=FileSaveRequest(UUID.randomUUID().toString(),read);pending=request
        update { it.copy(phase=FileSavePhase.Choosing,savedUri=null,feedback=null) };return request.id
    }
    fun result(id: String,destination: Uri?) {
        val request=pending?.takeIf { it.id==id }
        if(closed || request==null || state.phase!=FileSavePhase.Choosing) return
        if(destination==null) { pending=null;update { it.copy(phase=FileSavePhase.Idle,feedback=null) };return }
        update { it.copy(phase=FileSavePhase.Waiting) }
        // UNDISPATCHED installs cleanup before cancellation can overtake a just-returned document URI.
        writing=scope.launch(start=CoroutineStart.UNDISPATCHED) {
            var completed=false;var failure:String?=null
            try {
                foreground.first { it };currentCoroutineContext().ensureActive()
                check(!closed && pending==request && current()==request.read)
                update { it.copy(phase=FileSavePhase.Writing) }
                save(request,destination);currentCoroutineContext().ensureActive()
                check(!closed && foreground.value && pending==request && current()==request.read)
                completed=true;update { it.copy(phase=FileSavePhase.Saved,savedUri=destination.toString(),feedback="已保存到所选位置") }
            } catch(error: CancellationException) { failure="保存已中止，请重新选择位置";throw error }
            catch(_: Exception) { failure="无法保存文件，请检查来源和目标位置后重试" }
            finally {
                val removed=if(!completed) withContext(NonCancellable) { runCatching { discard(destination) }.getOrDefault(false) } else true
                if(pending==request) pending=null
                if(!completed) update { it.copy(phase=FileSavePhase.Idle,feedback=(failure ?: "保存已中止")+if(removed) "" else "；未完成的文件可能仍留在所选位置，请手动删除") }
            }
        }
    }
    fun present(mode: TemporaryFileMode) {
        val provider=prepare ?: return
        if(closed || !foreground.value || !state.available || pending!=null || writing?.isCompleted==false || presentation?.isCompleted==false) return
        val read=state.read ?: return;val request=FileSaveRequest(UUID.randomUUID().toString(),read)
        presentationRequest=request;launchMode=mode;claimed=false;launched=false;returned=CompletableDeferred()
        update { it.copy(opening=true,action=null,feedback=null) }
        presentation=scope.launch(start=CoroutineStart.UNDISPATCHED) {
            var lease:TemporaryResourceLease?=null
            try {
                check(current()==request.read)
                lease=provider(request);currentCoroutineContext().ensureActive()
                check(!closed && foreground.value && current()==request.read && lease.active)
                update { it.copy(action=TemporaryFileAction(request.id,lease.uri.toString(),read.descriptor.contentType,mode)) }
                coroutineScope {
                    val expiry=async { lease.awaitReleased() }
                    try { select<Unit> { requireNotNull(returned).onAwait { };expiry.onAwait { if(!closed) update { it.copy(feedback="临时文件已失效，请重新打开") } } } }
                    finally { expiry.cancelAndJoin() }
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { update { it.copy(feedback="暂时无法准备文件，请重试") } }
            finally {
                // Sharesheet completion does not prove the chosen app has finished reading.
                // Only a successfully launched share transfers ownership to the account/expiry watcher.
                if(mode!=TemporaryFileMode.Share || !launched) lease?.release()
                presentationRequest=null;returned=null;claimed=false;launched=false
                update { it.copy(opening=false,action=null) }
            }
        }
    }
    suspend fun claimPresentation(id: String): Boolean {
        val request=presentationRequest?.takeIf { it.id==id } ?: return false
        if(closed || !foreground.value || claimed || state.action?.id!=id) return false
        return try {
            val read=current()
            if(read!=request.read) { presentation?.cancel();false }
            else if(closed || !foreground.value || presentationRequest!=request || claimed) false
            else { claimed=true;update { it.copy(action=null) };true }
        } catch(error: CancellationException) { throw error }
        catch(_: Exception) { presentation?.cancel();false }
    }
    fun presentationLaunched(id: String) {
        if(presentationRequest?.id!=id || !claimed || closed) return
        launched=true
        if(launchMode==TemporaryFileMode.Share) { update { it.copy(feedback="已打开系统分享面板") };returned?.complete(Unit) }
    }
    fun presentationReturned(id: String) { if(presentationRequest?.id==id) returned?.complete(Unit) }
    fun presentationFailed(id: String) {
        if(presentationRequest?.id!=id) return
        update { it.copy(feedback=if(launchMode==TemporaryFileMode.Open) "未找到可打开此文件的应用，可先保存到文件" else "无法打开系统分享面板，请重试") }
        returned?.complete(Unit)
    }
    fun pickerFailed(id: String) { if(pending?.id==id && state.phase==FileSavePhase.Choosing) { pending=null;update { it.copy(phase=FileSavePhase.Idle,feedback="无法打开系统文件选择器，请重试") } } }
    fun openFailed() { update { it.copy(feedback="无法打开已保存文件，请在系统文件应用中查看或安装支持此格式的应用") } }
    fun retry() { if(!closed && foreground.value && pending==null && writing?.isCompleted!=false && presentation?.isCompleted!=false) { foreground(false);foreground(true) } }
    fun accepts(id: String)=!closed && pending?.id==id && state.phase==FileSavePhase.Choosing
    fun close() { if(closed) return;closed=true;pending=null;foreground.value=false;epoch++;owner.cancel();state=MessageFileState(selection) }
    suspend fun awaitClosed() { owner.join() }
}
