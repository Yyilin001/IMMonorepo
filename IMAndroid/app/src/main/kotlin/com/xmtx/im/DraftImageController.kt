package com.xmtx.im

import com.xmtx.im.client.*
import com.xmtx.im.platform.NormalizedPhoto
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class DraftImageSelection(val room: RoomId,val asset: String)
data class DraftImageState(val selection: DraftImageSelection,val available: Boolean=false,val attachment: SendAttachment?=null,
    val photo: NormalizedPhoto?=null,val loading: Boolean=false,val feedback: String?=null)

/** A local selection owner; it never creates a remote-message authorization or persists image bytes. */
internal class DraftImageController(val selection: DraftImageSelection,parent: CoroutineScope,private val changes: Flow<Long>,
    private val resolve: suspend ()->SendAttachment?,private val read: suspend (SendAttachment)->NormalizedPhoto,
    private val publish: (DraftImageState)->Unit) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=DraftImageState(selection);private set
    private var closed=false;private var active=false;private var generation=0L;private var request=0L
    private var observer: Job?=null;private var loading: Job?=null
    private fun update(body: (DraftImageState)->DraftImageState) { if(!closed) { state=body(state);publish(state) } }
    private fun clear() { request++;loading?.cancel();update { it.copy(photo=null,attachment=null,loading=false,feedback=null) } }
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;generation++;observer?.cancel();clear();update { it.copy(available=value) }
        if(value) {
            val epoch=generation
            observer=scope.launch { changes.collectLatest {
                try {
                    val source=resolve();currentCoroutineContext().ensureActive();require(source==null || source.asset==selection.asset && source.contentType.startsWith("image/"))
                    if(!closed && active && epoch==generation && source!=state.attachment) {
                        clear();update { it.copy(attachment=source) };if(source!=null) load(source)
                    }
                    if(!closed && active && epoch==generation && source==null) update { it.copy(feedback="这张图片已不在当前草稿中，或原件不可用") }
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { if(!closed && active && epoch==generation) { clear();update { it.copy(feedback="暂时无法读取草稿图片，请重试") } } }
            } }
        }
    }
    private fun load(source: SendAttachment) {
        val epoch=generation;val serial=++request
        loading?.cancel();update { it.copy(loading=true,feedback=null) }
        loading=scope.launch {
            try {
                val image=read(source);currentCoroutineContext().ensureActive()
                require(image.dimensions.width in 1..2048 && image.dimensions.height in 1..2048 && image.byteCount<=20*1024*1024)
                val current=resolve();currentCoroutineContext().ensureActive()
                if(valid(epoch,serial) && current==source) update { it.copy(photo=image) }
                else if(valid(epoch,serial)) { clear();update { it.copy(feedback="草稿图片已变化，请重新进入查看") } }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(epoch,serial)) update { it.copy(photo=null,feedback="无法显示这张图片，请检查原件后重试") } }
            finally { if(valid(epoch,serial)) update { it.copy(loading=false) } }
        }
    }
    private fun valid(epoch: Long,serial: Long)=!closed && active && generation==epoch && request==serial
    fun retry() { if(active && !closed) { foreground(false);foreground(true) } }
    suspend fun close()=withContext(NonCancellable) {
        if(!closed) { closed=true;active=false;generation++;scope.coroutineContext.job.cancelAndJoin();state=DraftImageState(selection) }
    }
}
