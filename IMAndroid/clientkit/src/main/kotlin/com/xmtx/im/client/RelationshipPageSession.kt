package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.Closeable

data class RelationshipPageState(val request:RelationshipPageRequest=RelationshipPageRequest(),val page:RelationshipPage=RelationshipPage(),
    val loading:Boolean=false,val canPrevious:Boolean=false,val feedback:String?=null,val closed:Boolean=false,
    val navigation:RelationshipNavigation?=null)

/** One UI-dispatcher owner. Results replace a finite window; viewport input never carries profile data. */
class RelationshipPageSession(private val store:RelationshipPageStore,private val actor:UserId,parent:CoroutineScope,
    changes:Flow<Long> = emptyFlow(),private val onClosed:()->Unit={}):Closeable {
    private data class Load(val request:RelationshipPageRequest,val anchor:RelationshipAnchor?=null,val preceding:Int=0)
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    private val mutable=MutableStateFlow(RelationshipPageState());val state=mutable.asStateFlow()
    private var initialized=false
    private var revision=0L;private var navigationRevision=0L;private var job:Job?=null;private var dirty=false
    private var viewport:RelationshipViewport?=null;private var viewportRevision=0L;private var scrolling=false
    private var active=Load(RelationshipPageRequest());private var hasEarlier=false
    private val history=ArrayDeque<Load>()
    private val observation=scope.launch {changes.collect {refresh()}}
    fun update(request:RelationshipPageRequest,restore:RelationshipViewport?=null) {
        if(state.value.closed) return
        initialized=true
        history.clear();hasEarlier=false;viewport=restore;viewportRevision++;scrolling=false
        val fresh=request.copy(cursor=null);mutable.value=RelationshipPageState(request=fresh)
        val anchor=restore?.anchor?.takeIf {store is RelationshipWindowStore}
        load(Load(fresh,anchor,minOf(10,fresh.limit-1)),restore=restore,debounce=true)
    }
    /** Called only for measured rows in the published window; null means the list header is visible. */
    fun observeViewport(target:UserId?,offset:Int=0,isScrolling:Boolean=false) {
        if(state.value.closed) return
        require(offset>=0)
        val row=target?.let {id->state.value.page.relationships.firstOrNull {it.target==id} ?: return}
        val next=row?.let {RelationshipViewport(RelationshipAnchor(it.target,it.updatedAt),offset)}
        if(next!=viewport || scrolling!=isScrolling) {viewport=next;scrolling=isScrolling;viewportRevision++}
        if(!scrolling && dirty && !state.value.loading) {dirty=false;refresh()}
    }
    fun next() {
        if(state.value.loading || state.value.closed) return
        val cursor=state.value.page.next ?: return;val previous=active
        load(Load(state.value.request.copy(cursor=cursor))) {if(history.size==256) history.removeFirst();history.addLast(previous)}
    }
    fun previous() {
        if(state.value.loading || state.value.closed) return
        if(history.isNotEmpty()) load(history.last()) {history.removeLast()}
        else if(hasEarlier && store is RelationshipWindowStore) {
            val first=state.value.page.relationships.firstOrNull() ?: return
            load(Load(state.value.request.copy(cursor=null),RelationshipAnchor(first.target,first.updatedAt),state.value.request.limit-1))
        }
    }
    fun first() {update(state.value.request)}
    fun refresh() {
        if(!initialized || state.value.closed) return
        if(state.value.loading || scrolling) {dirty=true;return}
        val anchor=viewport?.anchor ?: if(active.anchor!=null || active.request.cursor!=null)
            state.value.page.relationships.firstOrNull()?.let {RelationshipAnchor(it.target,it.updatedAt)} else null
        val next=if(store is RelationshipWindowStore && anchor!=null)
            Load(state.value.request.copy(cursor=null),anchor,if(viewport==null) 0 else minOf(10,state.value.request.limit-1)) else active
        load(next,restore=viewport,refresh=true)
    }
    fun retry() {if(initialized && !state.value.closed) load(active,restore=viewport)}
    private fun current(version:Long)=owner.isActive && !state.value.closed && version==revision
    private fun load(spec:Load,restore:RelationshipViewport?=null,debounce:Boolean=false,refresh:Boolean=false,commit:()->Unit={}) {
        if(!refresh) {viewport=restore;viewportRevision++;scrolling=false}
        val version=++revision;val observedViewport=viewportRevision;job?.cancel();dirty=false
        // A refresh retains the viewport while its independently authorized text owner handles visibility.
        mutable.value=state.value.copy(page=if(refresh) state.value.page else RelationshipPage(),loading=true,feedback=null)
        job=scope.launch {
            try {
                if(debounce && spec.request.query.isNotBlank()) delay(250)
                var page:RelationshipPage;var window:RelationshipWindow?=null
                while(true) {
                    ensureActive()
                    try {
                        window=if(spec.anchor!=null && store is RelationshipWindowStore)
                            store.relationshipWindow(actor,spec.request,spec.anchor,spec.preceding) else null
                        page=window?.page ?: store.relationshipPage(actor,spec.request);break
                    } catch(_:RelationshipPageFailure.Building) {store.processRelationshipSearchIndex(64);yield()}
                }
                ensureActive()
                require(page.relationships.size<=spec.request.limit && page.relationships.map {it.target}.distinct().size==page.relationships.size)
                if(page.next!=null && page.next==spec.request.cursor) throw RelationshipPageFailure.InvalidContinuation()
                if(current(version)) {
                    if(refresh && (scrolling || observedViewport!=viewportRevision)) {dirty=true;return@launch}
                    commit();active=spec;hasEarlier=window?.hasEarlier ?: false
                    // Tail windows backfill earlier rows. Keep the former first row visible in that case.
                    val restoring=restore ?: spec.anchor?.takeIf {refresh && page.relationships.firstOrNull()?.target!=it.target}?.let {RelationshipViewport(it)}
                    val target=restoring?.anchor?.target?.takeIf {id->page.relationships.any {it.target==id}}
                        ?: if(restoring!=null) window?.anchor?.target else null
                    val offset=if(target!=null && target==restoring?.anchor?.target) restoring.offset else 0
                    val navigation=RelationshipNavigation(++navigationRevision,target,offset)
                    mutable.value=RelationshipPageState(spec.request,page,canPrevious=history.isNotEmpty() || hasEarlier,navigation=navigation)
                }
            } catch(e:CancellationException) {throw e}
            catch(e:Exception) {if(current(version)) {
                active=spec
                mutable.value=state.value.copy(page=RelationshipPage(),feedback=when(e) {
                    is RelationshipPageFailure.InvalidQuery->"搜索文字不能超过 100 个 UTF-8 字节。"
                    is RelationshipPageFailure.InvalidContinuation->"列表来源已变化，请重新载入。"
                    else->"联系人读取失败，请重试。"
                })
            }}
            finally {if(current(version)) {mutable.value=state.value.copy(loading=false);if(dirty && !scrolling) {dirty=false;refresh()}}}
        }
    }
    override fun close() {
        if(state.value.closed) return
        revision++;owner.cancel();history.clear();viewport=null;mutable.value=RelationshipPageState(closed=true);onClosed()
    }
    suspend fun awaitClosed() {owner.join()}
}
