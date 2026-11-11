package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable

data class MessageSearchViewState(val request: MessageSearchRequest = MessageSearchRequest(""),
    val page: MessageSearchPage = MessageSearchPage(), val loading: Boolean = false, val indexing: Boolean = false,
    val canPrevious: Boolean = false, val feedback: String? = null, val restartRequired: Boolean = false, val closed: Boolean = false)

/** Serial UI-scope owner. Query edits debounce; each result page replaces the prior finite window. */
class MessageSearchSession(private val store: MessageSearchStore, private val actor: UserId, parent: CoroutineScope,
    private val closed: ()->Unit = {}) : Closeable {
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val mutable=MutableStateFlow(MessageSearchViewState());val state=mutable.asStateFlow()
    private var revision=0L;private var job: Job?=null;private var dirty=false
    private val history=mutableListOf<MessageSearchCursor?>()
    private var indexGeneration: Long?=null
    private var retryAction: (() -> Unit)?=null
    fun update(request: MessageSearchRequest) {
        if(state.value.closed) return
        val clean=request.copy(cursor=null)
        history.clear();mutable.value=MessageSearchViewState(request=clean)
        run(clean,debounce=true)
    }
    fun next() {
        if(state.value.loading || state.value.restartRequired) return
        val next=state.value.page.next ?: return
        val current=state.value.request
        run(current.copy(cursor=next),commit={history+=current.cursor})
    }
    fun previous() {
        if(state.value.loading || history.isEmpty()) return
        run(state.value.request.copy(cursor=history.last()),commit={history.removeAt(history.lastIndex)})
    }
    fun retry() {if(state.value.restartRequired) update(state.value.request) else retryAction?.invoke() ?: refresh()}
    fun refresh() {
        if(state.value.closed) return
        if(state.value.loading) {dirty=true;return}
        run(state.value.request)
    }
    fun indexChanged(progress: MessageSearchProgress) {
        if(state.value.closed) return
        val replaced=indexGeneration?.let {it!=progress.generation} == true
        indexGeneration=progress.generation
        if(replaced) update(state.value.request) else if(progress.ready || state.value.page.hits.isNotEmpty()) refresh()
    }
    fun indexFailed() {if(!state.value.closed) mutable.value=state.value.copy(loading=false,indexing=false,feedback="本地搜索索引暂不可用，请重试。")}
    private fun current(version: Long)=owner.isActive && !state.value.closed && revision==version
    private fun run(request: MessageSearchRequest, debounce: Boolean=false, commit: ()->Unit={}) {
        if(state.value.closed) return
        val version=++revision;job?.cancel();dirty=false;retryAction=null
        if(request.query.isEmpty() && request.content==MessageSearchContent.All && request.sender==null && request.scope !is MessageSearchScope.Sender) {
            mutable.value=MessageSearchViewState(request=request);return
        }
        mutable.value=state.value.copy(loading=true,indexing=false,feedback=null,restartRequired=false)
        job=scope.launch {
            try {
                if(debounce) delay(200)
                val page=store.searchMessages(actor,request)
                if(!current(version)) return@launch
                require(page.hits.size<=request.limit && page.hits.map {it.message}.distinct().size==page.hits.size)
                if(page.next!=null && page.next==request.cursor) throw MessageSearchFailure.InvalidContinuation()
                commit();mutable.value=state.value.copy(request=request,page=page,canPrevious=history.isNotEmpty(),indexing=false)
            } catch(e: CancellationException) {throw e}
            catch(_: MessageSearchFailure.Building) {if(current(version)) mutable.value=state.value.copy(page=MessageSearchPage(),indexing=true)}
            catch(_: MessageSearchFailure.InvalidContinuation) {if(current(version)) mutable.value=state.value.copy(feedback="搜索范围或索引已变化，请重新搜索。",restartRequired=true)}
            catch(_: Exception) {if(current(version)) {
                retryAction={run(request,commit=commit)}
                mutable.value=state.value.copy(feedback="本地搜索失败，请重试。")
            }}
            finally {if(current(version)) {mutable.value=state.value.copy(loading=false);if(dirty) {dirty=false;refresh()}}}
        }
    }
    override fun close() {
        if(state.value.closed) return
        revision++;owner.cancel();history.clear();retryAction=null;mutable.value=MessageSearchViewState(closed=true);closed()
    }
    suspend fun awaitClosed() {owner.join()}
}
