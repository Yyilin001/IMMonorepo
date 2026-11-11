package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable

data class MessageSourceState(val ids: PersistentSet<MessageId> = persistentSetOf(),
    val messages: PersistentMap<MessageId,Message> = persistentMapOf(),val loaded: Boolean=false,
    val loading: Boolean=false,val feedback: String?=null,val closed: Boolean=false)

/** Serial page owner, containing only the currently requested finite set of sources.
 * Selection changes clear the previous bodies immediately. Invalidations during a read
 * coalesce into one follow-up and prevent that obsolete read from being published. */
class MessageSourceSession(private val store: MessageSourceStore,val room: RoomId,val viewer: UserId,
    parent: CoroutineScope,private val closed: ()->Unit={}) : Closeable {
    private val owner=SupervisorJob(parent.coroutineContext[Job])
    private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val mutableState=MutableStateFlow(MessageSourceState())
    val state=mutableState.asStateFlow()
    private var revision=0L
    private var job: Job?=null
    private var dirty=false
    fun select(ids: PersistentSet<MessageId>) {
        require(ids.size<=100)
        if(state.value.closed || state.value.loaded && state.value.ids==ids || state.value.loading && state.value.ids==ids) return
        revision++;job?.cancel();dirty=false
        mutableState.value=MessageSourceState(ids=ids,loaded=ids.isEmpty())
        if(ids.isNotEmpty()) read()
    }
    fun refresh() {
        if(state.value.closed || state.value.ids.isEmpty()) return
        if(state.value.loading) {dirty=true;return}
        read()
    }
    private fun read() {
        val version=++revision;val ids=state.value.ids
        job?.cancel();dirty=false
        mutableState.value=state.value.copy(loading=true,feedback=null)
        job=scope.launch {
            try {
                val messages=store.messageSources(room,viewer,ids)
                require(messages.size<=ids.size && messages.all {(id,message)->id in ids && id==message.id &&
                    message.roomId==room && !message.withdrawn && !message.redacted && message.delivery==Delivery.Accepted && message.revision>0})
                if(current(version) && !dirty) mutableState.value=state.value.copy(messages=messages,loaded=true)
            } catch(e: CancellationException) {throw e}
            catch(_: Exception) {if(current(version) && !dirty) mutableState.value=state.value.copy(messages=persistentMapOf(),loaded=false,feedback="本地消息读取失败，请重试。")}
            finally {if(current(version)) {
                mutableState.value=state.value.copy(loading=false)
                if(dirty) {dirty=false;read()}
            }}
        }
    }
    private fun current(version: Long)=!state.value.closed && revision==version
    override fun close() {
        if(state.value.closed) return
        revision++;owner.cancel();mutableState.value=MessageSourceState(closed=true);closed()
    }
    suspend fun awaitClosed() {owner.join()}
}
