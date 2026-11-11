package com.xmtx.im

import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class MessageImageSelection(val location: MediaMessageLocation,val media: String) {
    val key=ResourceKey(ResourceHome.Room(location.room),media)
}
data class MessageImageFrame(val read: MessageResourceRead,val encoded: ByteString,val deadlineNanos: Long,val original: Boolean) {
    init { require(encoded.size() in 1..20*1024*1024) }
    fun valid()=deadlineNanos-System.nanoTime()>0
    override fun toString()="MessageImageFrame(key=${read.descriptor.key}, original=$original, pixels=<redacted>)"
}
data class MessageImageState(val selection: MessageImageSelection,val available: Boolean=false,val loading: Boolean=false,
    val originalLoading: Boolean=false,val frame: MessageImageFrame?=null,val feedback: String?=null)

/** Navigation entry owner. Every asynchronous result is fenced by route, foreground and source generation. */
internal class MessageImageController(val selection: MessageImageSelection,parent: CoroutineScope,
    private val changes: Flow<Long>,private val generation: suspend ()->String,
    private val read: suspend (Boolean)->MessageImageFrame,private val publish: (MessageImageState)->Unit,
    private val expiry: suspend (Long)->Unit=::awaitPresentationExpiry) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=MessageImageState(selection);private set
    private var closed=false;private var active=false;private var epoch=0L;private var request=0L;private var token: String?=null
    private var observer: Job?=null;private var task: Job?=null;private var expiration: Job?=null
    private fun update(body: (MessageImageState)->MessageImageState) { if(!closed) { state=body(state);publish(state) } }
    private fun clear() { request++;task?.cancel();expiration?.cancel();update { it.copy(frame=null,loading=false,originalLoading=false) } }
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;epoch++;observer?.cancel();clear();token=null
        update { it.copy(available=value,feedback=null) }
        if(value) {
            val e=epoch
            observer=scope.launch { changes.collectLatest {
                try {
                    val next=generation();currentCoroutineContext().ensureActive()
                    if(!closed && active && epoch==e && token!=next) { clear();token=next;load(false) }
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { if(!closed && active && epoch==e) { clear();token=null;update { it.copy(feedback="图片来源暂不可用，请重试") } } }
            } }
        }
    }
    fun load(original: Boolean) {
        if(closed || !active || token==null) return
        val e=epoch;val n=++request;val expected=token
        task?.cancel();update { it.copy(loading=!original,originalLoading=original,feedback=null) }
        task=scope.launch {
            try {
                val result=read(original);currentCoroutineContext().ensureActive()
                check(result.read.descriptor.key==selection.key && result.read.source.room==selection.location.room && result.read.source.message==selection.location.message && result.read.generation==expected && result.original==original && result.valid())
                if(valid(e,n,expected)) {
                    expiration?.cancel();update { it.copy(frame=result,feedback=null) }
                    expiration=scope.launch { expiry(result.deadlineNanos);if(!closed && active && epoch==e && token==expected && state.frame===result) update { it.copy(frame=null,feedback="图片查看许可已过期，请重新加载") } }
                }
            } catch(error: CancellationException) { throw error }
            catch(error: Exception) {
                if(valid(e,n,expected)) {
                    val denied=error is ClientFailure.SignedOut || error is MediaReadFailure && error.reason in setOf(MediaReadFailureReason.Denied,MediaReadFailureReason.AuthorizationUnavailable,MediaReadFailureReason.SourceChanged,MediaReadFailureReason.Expired)
                    if(denied) expiration?.cancel()
                    update { it.copy(frame=if(denied) null else it.frame,feedback=if(denied) "图片查看权限已变化，请重新加载" else if(original) "暂时无法读取原图，请重试" else "图片已不可用或暂时无法加载，请重试") }
                }
            }
            finally { if(valid(e,n,expected)) update { it.copy(loading=false,originalLoading=false) } }
        }
    }
    fun retry() { if(active && !closed) { if(token==null) { foreground(false);foreground(true) } else load(false) } }
    private fun valid(e: Long,n: Long,t: String?)=!closed && active && epoch==e && request==n && token==t
    fun close() { if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=MessageImageState(selection) }
}
