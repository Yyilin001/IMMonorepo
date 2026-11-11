package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*

data class ResourceSelectionState(val selected:PersistentList<ResourceKey>?=null,val working:Boolean=false,
    val preview:ResourceSelectionCleanupPlan?=null,val result:ResourceCleanupResult?=null,val feedback:String?=null,
    val retentionResult:ResourceRetentionBatchResult?=null)

/** Page-owned selection. Neither selection nor deletion authority survives leaving the foreground. */
internal class ResourceSelectionController(parent:CoroutineScope,
    private val preview:suspend (PersistentList<ResourceKey>)->ResourceSelectionCleanupPlan,
    private val commit:suspend (ResourceCleanupPlan)->ResourceCleanupResult,
    private val publish:(ResourceSelectionState)->Unit,
    private val retain:suspend (PersistentList<ResourceKey>,Boolean)->ResourceRetentionBatchResult={_,_->error("批量保留未启用")}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceSelectionState();private set
    private var active=false;private var closed=false;private var epoch=0L;private var job:Job?=null
    private fun update(value:ResourceSelectionState) {if(!closed) {state=value;publish(value)}}
    private fun editable()=active && !closed && !state.working && state.preview==null
    fun foreground(value:Boolean) {if(closed || active==value) return;active=value;reset()}
    fun reset() {if(closed) return;epoch++;job?.cancel();update(ResourceSelectionState())}
    fun toggleMode() {if(editable()) update(ResourceSelectionState(selected=if(state.selected==null) persistentListOf() else null))}
    fun toggle(key:ResourceKey) {
        if(!editable()) return
        val values=state.selected ?: return
        if(key !in values && values.size>=100) return
        update(state.copy(selected=if(key in values) values.remove(key) else values.add(key),result=null,feedback=null,retentionResult=null))
    }
    fun selectPage(keys:PersistentList<ResourceKey>) {
        if(editable() && state.selected!=null) update(state.copy(selected=keys.distinct().take(100).toPersistentList(),result=null,feedback=null,retentionResult=null))
    }
    fun setRetained(value:Boolean) {
        if(!editable()) return
        val selected=state.selected?.takeIf {it.isNotEmpty()} ?: return
        execute("未能取得完整操作结果，部分项目可能已更新，请刷新核对后重试") {
            val result=retain(selected,value)
            check(result.retained==value && result.items.map {it.key}==selected.distinct())
            ResourceSelectionState(selected=result.failedKeys,retentionResult=result)
        }
    }
    fun prepare() {
        if(!editable()) return
        val selected=state.selected?.takeIf {it.isNotEmpty()} ?: return
        execute("暂时无法检查所选缓存，请重新检查") {state.copy(working=false,preview=preview(selected))}
    }
    fun dismiss() {if(active && !closed && !state.working) update(state.copy(preview=null))}
    fun confirm() {
        val plan=state.preview?.plan?.takeIf {it.fileCount>0} ?: return
        execute("预览已失效或清理未完整完成，请重新检查") {
            val result=commit(plan)
            ResourceSelectionState(selected=persistentListOf(),result=result)
        }
    }
    private fun execute(failure:String,body:suspend ()->ResourceSelectionState) {
        if(!active || closed || state.working) return
        val expected=epoch;update(state.copy(working=true,preview=null,result=null,feedback=null,retentionResult=null))
        job=scope.launch {
            try {val value=body();ensureActive();if(active && !closed && epoch==expected) update(value)}
            catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(active && !closed && epoch==expected) update(state.copy(working=false,preview=null,feedback=failure))}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ResourceSelectionState()}
}
