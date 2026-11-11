package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable

data class FavoriteMessageItem(val room: RoomId,val message: MessageId,val text: String,val createdAt: Long,val updatedAt: Long)
data class FavoriteMessageCursor(val scope: String,val updatedAt: Long,val room: RoomId,val message: MessageId)
sealed interface FavoriteMessageSelection {
    data object Latest: FavoriteMessageSelection
    data class Before(val cursor: FavoriteMessageCursor): FavoriteMessageSelection
    data class After(val cursor: FavoriteMessageCursor): FavoriteMessageSelection
}
data class FavoriteMessagePage(val items: PersistentList<FavoriteMessageItem> = persistentListOf(),
    val previous: FavoriteMessageCursor?=null,val next: FavoriteMessageCursor?=null)
interface FavoriteMessageStore {
    suspend fun favoriteMessages(viewer: UserId,selection: FavoriteMessageSelection=FavoriteMessageSelection.Latest,limit: Int=50): FavoriteMessagePage
}
data class FavoriteMessageState(val selection: FavoriteMessageSelection=FavoriteMessageSelection.Latest,val page: FavoriteMessagePage=FavoriteMessagePage(),
    val loading: Boolean=false,val loaded: Boolean=false,val feedback: String?=null,val closed: Boolean=false)

/** One finite page, bidirectional keysets and no accumulated bodies or cursor history. Main/serial scope owned. */
class FavoriteMessageSession(private val store: FavoriteMessageStore,val viewer: UserId,parent: CoroutineScope,private val closed: ()->Unit={}) : Closeable {
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val mutable=MutableStateFlow(FavoriteMessageState());val state=mutable.asStateFlow()
    private var revision=0L;private var dirty=false;private var job: Job?=null
    fun latest()=read(FavoriteMessageSelection.Latest)
    fun next() {if(!state.value.loading) state.value.page.next?.let {read(FavoriteMessageSelection.Before(it))}}
    fun previous() {if(!state.value.loading) state.value.page.previous?.let {read(FavoriteMessageSelection.After(it))}}
    fun refresh() {
        if(state.value.closed) return
        if(state.value.loading) {dirty=true;return}
        read(state.value.selection,retain=true)
    }
    private fun read(selection: FavoriteMessageSelection,retain: Boolean=false) {
        if(state.value.closed) return
        val version=++revision;job?.cancel();dirty=false
        mutable.value=if(retain) state.value.copy(loading=true,feedback=null) else FavoriteMessageState(selection=selection,loading=true)
        job=scope.launch {
            try {
                val page=store.favoriteMessages(viewer,selection,50)
                require(page.items.size<=50 && page.items.map {it.room to it.message}.distinct().size==page.items.size)
                if(current(version) && !dirty) mutable.value=state.value.copy(page=page,loaded=true)
            } catch(e: CancellationException) {throw e}
            catch(_: Exception) {if(current(version) && !dirty) mutable.value=state.value.copy(page=FavoriteMessagePage(),loaded=false,feedback="本地收藏读取失败，请重试。")}
            finally {if(current(version)) {mutable.value=state.value.copy(loading=false);if(dirty) read(selection,retain=true)}}
        }
    }
    private fun current(version: Long)=owner.isActive && !state.value.closed && revision==version
    override fun close() {if(!state.value.closed) {revision++;owner.cancel();mutable.value=FavoriteMessageState(closed=true);closed()}}
    suspend fun awaitClosed() {owner.join()}
}
