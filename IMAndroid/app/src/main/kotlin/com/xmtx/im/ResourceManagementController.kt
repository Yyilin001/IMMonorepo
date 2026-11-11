package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class ResourceLibraryState(val available:Boolean=false,val loading:Boolean=false,val category:ResourceCategory=ResourceCategory.All,
    val search:String="",val retainedOnly:Boolean=false,val positions:PersistentList<ResourceCatalogCursor?> = persistentListOf(null),
    val entries:PersistentList<ResourceCatalogEntry> = persistentListOf(),val next:ResourceCatalogCursor?=null,val indexing:Boolean=false,val feedback:String?=null,
    val selection:ResourceSelectionState=ResourceSelectionState())

internal class ResourceLibraryController(parent:CoroutineScope,private val changes:Flow<Long>,
    private val directory:suspend (ResourceCatalogQuery)->ResourceCatalogPage,private val publish:(ResourceLibraryState)->Unit,
    preview:suspend (PersistentList<ResourceKey>)->ResourceSelectionCleanupPlan={error("所选清理未启用")},
    commit:suspend (ResourceCleanupPlan)->ResourceCleanupResult={error("所选清理未启用")},
    retain:suspend (PersistentList<ResourceKey>,Boolean)->ResourceRetentionBatchResult={_,_->error("批量保留未启用")}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceLibraryState();private set
    private var active=false;private var closed=false;private var version=0L;private var observer:Job?=null
    private fun update(body:(ResourceLibraryState)->ResourceLibraryState) {if(!closed) {state=body(state);publish(state)}}
    private val selection=ResourceSelectionController(scope,preview,commit,publish={value->update {it.copy(selection=value)}},retain=retain)
    fun toggleSelection() {if(!state.loading) selection.toggleMode()}
    fun select(key:ResourceKey) {if(!state.loading && state.entries.any {it.descriptor.key==key}) selection.toggle(key)}
    fun selectPage() {if(!state.loading) selection.selectPage(state.entries.map {it.descriptor.key}.toPersistentList())}
    fun previewSelection() {if(!state.loading) selection.prepare()}
    fun confirmSelection()=selection.confirm()
    fun dismissSelection()=selection.dismiss()
    fun retainSelection(value:Boolean) {if(!state.loading) selection.setRetained(value)}
    fun foreground(value:Boolean) {
        if(closed || active==value) return
        active=value;version++;observer?.cancel()
        selection.foreground(value)
        update {it.copy(available=value,entries=persistentListOf(),next=null,loading=false,feedback=null)}
        if(value) reload()
    }
    fun query(text:String,category:ResourceCategory,retained:Boolean) {
        if(!active || closed || state.selection.working || text.toByteArray(Charsets.UTF_8).size>255 || text==state.search && category==state.category && retained==state.retainedOnly) return
        selection.reset()
        update {it.copy(search=text,category=category,retainedOnly=retained,positions=persistentListOf(null))};reload()
    }
    fun page(next:Boolean) {
        if(!active || closed || state.loading || state.selection.working || state.selection.preview!=null) return
        if(next) {val cursor=state.next ?: return;update {it.copy(positions=it.positions.add(cursor))}}
        else {if(state.positions.size==1) return;update {it.copy(positions=it.positions.removeAt(it.positions.lastIndex))}}
        reload()
    }
    fun reload() {
        if(!active || closed || state.selection.working || state.selection.preview!=null) return
        observer?.cancel();val expected=++version
        val query=ResourceCatalogQuery(category=state.category,search=state.search,before=state.positions.last(),limit=30,retainedOnly=state.retainedOnly)
        update {it.copy(loading=true,entries=persistentListOf(),next=null,feedback=null)}
        observer=scope.launch {changes.collectLatest {
            if(!active || closed || version!=expected) return@collectLatest
            try {
                val page=directory(query);ensureActive()
                if(active && !closed && version==expected) update {it.copy(loading=false,entries=page.entries,next=page.nextCursor,indexing=page.isIndexing,feedback=null)}
            } catch(e:CancellationException) {throw e} catch(_:Exception) {
                if(active && !closed && version==expected) {selection.reset();update {it.copy(loading=false,entries=persistentListOf(),next=null,feedback="暂时无法读取资源，请刷新重试")}}
            }
        }}
    }
    fun close() {if(closed) return;closed=true;active=false;version++;selection.close();scope.cancel();state=ResourceLibraryState()}
}

data class ResourceDetailState(val key:ResourceKey,val available:Boolean=false,val loading:Boolean=false,val working:Boolean=false,
    val snapshot:ResourceDetailSnapshot?=null,val before:ResourceSourceCursor?=null,val feedback:String?=null,val readFailure:String?=null,val queuedDownload:String?=null) {
    val original get()=snapshot?.variants?.firstOrNull {it.descriptor.key.rendition==ResourceRendition.Original}
    val usable get()=available && !loading && !working && snapshot!=null
}

internal class ResourceDetailController(val key:ResourceKey,parent:CoroutineScope,private val changes:Flow<Long>,
    private val details:suspend (ResourceKey,ResourceSourceCursor?)->ResourceDetailSnapshot?,
    private val retain:suspend (ResourceVariantKey,Boolean)->Unit,private val publish:(ResourceDetailState)->Unit,
    private val enqueue:suspend (ResourceKey,MessageResourceSource)->String={_,_->error("下载任务暂不可用")}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceDetailState(key);private set
    private var active=false;private var closed=false;private var epoch=0L;private var version=0L
    private var observer:Job?=null;private var command:Job?=null
    private fun update(body:(ResourceDetailState)->ResourceDetailState) {if(!closed) {state=body(state);publish(state)}}
    private fun valid(e:Long)=active && !closed && epoch==e
    fun foreground(value:Boolean) {
        if(closed || active==value) return
        active=value;epoch++;version++;observer?.cancel();command?.cancel()
        update {it.copy(available=value,snapshot=null,loading=false,working=false,feedback=null,readFailure=null)}
        if(value) observe()
    }
    fun reload() {if(active && !closed && !state.working) observe(keepSnapshot=true)}
    fun page(next:Boolean) {
        if(!state.usable) return
        val cursor=if(next) state.snapshot?.sources?.nextCursor ?: return else null
        update {it.copy(before=cursor)};observe()
    }
    private fun observe(keepSnapshot:Boolean=false,finishCommand:Boolean=false) {
        observer?.cancel();val e=epoch;val v=++version;val before=state.before
        update {it.copy(loading=true,working=if(finishCommand) false else it.working,snapshot=if(keepSnapshot) it.snapshot else null,readFailure=null)}
        observer=scope.launch {changes.collectLatest {
            if(!valid(e) || version!=v) return@collectLatest
            // Keep the same query's metadata stable during refresh, as on iOS. This is
            // never a read grant: mutations and byte access check current store authority.
            try {
                val snapshot=details(key,before);ensureActive();require(snapshot==null || snapshot.descriptor.key==key)
                if(valid(e) && version==v) update {it.copy(loading=false,snapshot=snapshot,readFailure=if(snapshot==null) "资源或原消息当前不可访问" else null)}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(valid(e) && version==v) update {it.copy(loading=false,snapshot=null,readFailure="暂时无法读取资源，请刷新重试")}
            }
        }}
    }
    fun setRetained(value:Boolean) {
        if(!state.usable || closed) return
        val original=state.original ?: return
        if(original.retained==value) return
        val e=epoch;update {it.copy(working=true,feedback=null)}
        command=scope.launch {
            try {
                retain(original.descriptor.key,value);ensureActive()
                if(valid(e)) update {it.copy(feedback=if(value) "已保留本机；未下载的文件仍需联网获取" else "已解除保留，文件可按缓存策略回收")}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(valid(e)) update {it.copy(feedback="未能更改保留状态，请刷新后重试")}
            } finally {if(valid(e)) observe(keepSnapshot=true,finishCommand=true)}
        }
    }
    fun download() {
        if(!state.usable || closed || state.original==null) return
        val source=state.snapshot?.sources?.sources?.firstOrNull() ?: return
        val e=epoch;update {it.copy(working=true,feedback=null)}
        command=scope.launch {
            try {
                val id=enqueue(key,source);ensureActive()
                if(valid(e)) update {it.copy(queuedDownload=id,feedback="已保存下载请求，可在下载任务中查看或继续处理")}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(valid(e)) update {it.copy(feedback="未能安排下载，请刷新或前往下载任务检查已有请求")}
            } finally {if(valid(e)) observe(keepSnapshot=true,finishCommand=true)}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ResourceDetailState(key)}
}
