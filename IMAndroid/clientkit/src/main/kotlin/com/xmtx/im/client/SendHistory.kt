package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable

enum class SendRecordStatus { Pending, Confirming, NeedsAttention, ExpiredUnsubmitted, Closed, Rejected, AcceptedAwaitingProjection, Accepted, WaitingForNetwork, WaitingForAuthentication }

/** message is present only while the current projected source is readable. */
data class SendHistoryItem(val operation: String,val text: String,val createdAt: Long,val delivery: Delivery,val message: MessageId?=null,val status: SendRecordStatus=SendRecordStatus.Pending,
    val canReplaceText: Boolean=false,val replacement: String?=null,val abandoned: Boolean=false) {
    val canAbandonText get()=canReplaceText
}
/** Retire a proven-unsent independent text command locally; never cancel an unknown remote outcome. */
interface TextSendAbandonmentStore {
    suspend fun abandonUnsentText(room: RoomId,viewer: UserId,operation: String)
}
/** Atomically replace only a proven-unsent, media-free command not owned by an attachment intent.
 * Repeated requests for the same original return the same durable replacement identity.
 */
interface TextSendReplacementStore {
    suspend fun replaceUnsentText(room: RoomId,viewer: UserId,operation: String,now: Long): String
}
data class SendHistoryCursor(val scope: String,val room: RoomId,val row: Long)
sealed interface SendHistorySelection {
    data object Latest: SendHistorySelection
    data class Before(val cursor: SendHistoryCursor): SendHistorySelection
    data class After(val cursor: SendHistoryCursor): SendHistorySelection
}
data class SendHistoryPage(val items: PersistentList<SendHistoryItem> = persistentListOf(),
    val previous: SendHistoryCursor?=null,val next: SendHistoryCursor?=null)
interface SendHistoryStore {
    suspend fun sendHistory(room: RoomId,viewer: UserId,selection: SendHistorySelection=SendHistorySelection.Latest,limit: Int=50): SendHistoryPage
}
data class SendHistoryState(val selection: SendHistorySelection=SendHistorySelection.Latest,val page: SendHistoryPage=SendHistoryPage(),
    val loading: Boolean=false,val loaded: Boolean=false,val feedback: String?=null,val closed: Boolean=false)

/** One finite page, bidirectional keysets and no accumulated bodies or cursor history. Main/serial scope owned. */
class SendHistorySession(private val store: SendHistoryStore,val room: RoomId,val viewer: UserId,parent: CoroutineScope,private val closed: ()->Unit={}) : Closeable {
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val mutable=MutableStateFlow(SendHistoryState());val state=mutable.asStateFlow()
    private var revision=0L;private var dirty=false;private var job: Job?=null
    fun latest()=read(SendHistorySelection.Latest)
    fun next() {if(!state.value.loading) state.value.page.next?.let {read(SendHistorySelection.Before(it))}}
    fun previous() {if(!state.value.loading) state.value.page.previous?.let {read(SendHistorySelection.After(it))}}
    fun refresh() {
        if(state.value.closed) return
        if(state.value.loading) {dirty=true;return}
        read(state.value.selection,retain=true)
    }
    private fun read(selection: SendHistorySelection,retain: Boolean=false) {
        if(state.value.closed) return
        val version=++revision;job?.cancel();dirty=false
        mutable.value=if(retain) state.value.copy(loading=true,feedback=null) else SendHistoryState(selection=selection,loading=true)
        job=scope.launch {
            try {
                val page=store.sendHistory(room,viewer,selection,50)
                require(page.items.size<=50 && page.items.map {it.operation}.distinct().size==page.items.size)
                if(current(version) && !dirty) mutable.value=state.value.copy(page=page,loaded=true)
            } catch(e: CancellationException) {throw e}
            catch(_: Exception) {if(current(version) && !dirty) mutable.value=state.value.copy(page=SendHistoryPage(),loaded=false,feedback="本地发送记录读取失败，请重试。")}
            finally {if(current(version)) {mutable.value=state.value.copy(loading=false);if(dirty) read(selection,retain=true)}}
        }
    }
    private fun current(version: Long)=owner.isActive && !state.value.closed && revision==version
    override fun close() {if(!state.value.closed) {revision++;owner.cancel();mutable.value=SendHistoryState(closed=true);closed()}}
    suspend fun awaitClosed() {owner.join()}
}
