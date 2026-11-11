package com.xmtx.im

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.*

data class ResourceStorageState(val available:Boolean=false,val working:Boolean=false,val snapshot:ResourceStorageSnapshot?=null,val feedback:String?=null,
    val cleanupPlan:ResourceCleanupPlan?=null,val cleanupResult:ResourceCleanupResult?=null)
internal class ResourceStorageController(parent:CoroutineScope,private val read:suspend ()->ResourceStorageSnapshot,
    private val write:suspend (Long)->ResourceStoragePolicyResult,private val publish:(ResourceStorageState)->Unit,
    private val preview:suspend ()->ResourceCleanupPlan={error("清理未启用")},
    private val commit:suspend (ResourceCleanupPlan)->ResourceCleanupResult={error("清理未启用")},
    private val writeManaged:suspend (Long?)->ResourceStoragePolicyResult={error("总额度未启用")}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceStorageState();private set
    private var closed=false;private var epoch=0L;private var job:Job?=null
    private fun update(value:ResourceStorageState) {if(!closed) {state=value;publish(value)}}
    fun foreground(active:Boolean) {
        if(closed || state.available==active) return
        epoch++;job?.cancel();update(ResourceStorageState(available=active));if(active) refresh()
    }
    fun refresh()=execute {ResourceStorageState(true,snapshot=read())}
    fun cacheLimit(bytes:Long) {if(state.snapshot==null) return;execute {
        val result=write(bytes);ResourceStorageState(true,snapshot=result.snapshot,feedback=if(result.cleanupDeferred) "额度已保存，部分缓存仍在使用或暂未完成清理，可稍后刷新" else "缓存额度已保存")
    }}
    fun managedLimit(bytes:Long?) {if(state.snapshot==null) return;execute {
        val result=writeManaged(bytes);ResourceStorageState(true,snapshot=result.snapshot,feedback=if(result.cleanupDeferred) "总额度已保存，受保护或正在使用的文件可能仍超出额度" else "托管总额度已保存")
    }}
    fun prepareCleanup() {if(state.snapshot==null) return;execute("暂时无法检查缓存，请刷新后重试") {
        val plan=preview();state.copy(working=false,cleanupPlan=plan.takeIf {it.fileCount>0},feedback=if(plan.fileCount==0) "没有可清理的缓存，保留文件、待发送原件和正在使用的文件会跳过" else null)
    }}
    fun dismissCleanup() {if(!closed && !state.working) update(state.copy(cleanupPlan=null))}
    fun confirmCleanup() {
        val plan=state.cleanupPlan ?: return
        execute("预览已失效或清理未完整完成，请刷新后重新检查") {
            val result=commit(plan)
            val snapshot=try {read()} catch(error:CancellationException) {throw error} catch(_:Exception) {null}
            ResourceStorageState(true,snapshot=snapshot,cleanupResult=result,feedback=if(snapshot==null) "清理已执行，暂时无法读取最新占用，请刷新" else null)
        }
    }
    private fun execute(failure:String="暂时无法读取或更新存储状态，请刷新核对已保存的设置",body:suspend ()->ResourceStorageState) {
        if(closed || !state.available || state.working) return
        val e=epoch;update(state.copy(working=true,feedback=null,cleanupPlan=null,cleanupResult=null))
        job=scope.launch {
            try {val result=body();ensureActive();if(!closed && state.available && e==epoch) update(result)}
            catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(!closed && state.available && e==epoch) update(state.copy(working=false,snapshot=null,cleanupPlan=null,feedback=failure))}
        }
    }
    fun close() {if(closed) return;closed=true;epoch++;scope.cancel();state=ResourceStorageState()}
}

@Composable internal fun ResourceStorageScreen(state:ResourceStorageState,active:Boolean,demo:Boolean,refresh:()->Unit,
    cacheLimit:(Long)->Unit,retention:()->Unit,downloads:()->Unit,preview:()->Unit={},confirm:()->Unit={},dismiss:()->Unit={},managedLimit:(Long?)->Unit={}) {
    val context=LocalContext.current;val allowed=active && rememberReadForeground() && state.available && !demo && !state.working
    var options by remember {mutableStateOf(false)};var managedOptions by remember {mutableStateOf(false)}
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).testTag("resource-storage"),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        if(state.working) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(demo) Text("登录后可查看账号资源文件占用")
        state.snapshot?.let {s->
            Text("资源文件占用",style=MaterialTheme.typography.titleLarge)
            for((label,bytes) in listOf("聊天及其他缓存" to s.cacheAllocatedBytes,"保留本机" to s.retainedAllocatedBytes,"待发送原件" to s.originalAllocatedBytes,"临时传输" to s.transferAllocatedBytes,"合计" to s.totalAllocatedBytes)) {
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {Text(label);Text(Formatter.formatShortFileSize(context,bytes))}
            }
            Text("仅统计此账号资源文件的实际磁盘占用，共享文件只计一次。聊天记录和应用其他数据不计入，点击刷新可重新读取。",style=MaterialTheme.typography.bodySmall)
            HorizontalDivider()
            Box {
                OutlinedButton({options=true},enabled=allowed,modifier=Modifier.testTag("storage-cache-limit")) {Text("缓存额度：${Formatter.formatShortFileSize(context,s.policy.maximumCacheBytes)}")}
                DropdownMenu(options,{options=false}) {
                    for(mb in listOf(256L,512L,1024L,2048L,4096L)) DropdownMenuItem(text={Text(Formatter.formatShortFileSize(context,mb*1024*1024))},onClick={options=false;cacheLimit(mb*1024*1024)},enabled=allowed,modifier=Modifier.testTag("storage-cache-$mb"))
                }
            }
            Box {
                OutlinedButton({managedOptions=true},enabled=allowed,modifier=Modifier.testTag("storage-managed-limit")) {Text("托管总额度：${s.policy.maximumManagedBytes?.let {Formatter.formatShortFileSize(context,it)} ?: "不设上限"}")}
                DropdownMenu(managedOptions,{managedOptions=false}) {
                    DropdownMenuItem(text={Text("不设上限")},onClick={managedOptions=false;managedLimit(null)},enabled=allowed,modifier=Modifier.testTag("storage-managed-unlimited"))
                    for(mb in listOf(1024L,2048L,4096L,8192L)) DropdownMenuItem(text={Text(Formatter.formatShortFileSize(context,mb*1024*1024))},onClick={managedOptions=false;managedLimit(mb*1024*1024)},enabled=allowed,modifier=Modifier.testTag("storage-managed-$mb"))
                }
            }
            Text("托管额度已占用：${Formatter.formatShortFileSize(context,s.managedChargedBytes)}。包含文件与传输预留，因此可能高于实际磁盘占用。",style=MaterialTheme.typography.bodySmall)
            if(s.managedOverageBytes>0) Text("当前仍超出托管总额度 ${Formatter.formatShortFileSize(context,s.managedOverageBytes)}，新文件可能无法加入",color=MaterialTheme.colorScheme.error,modifier=Modifier.testTag("storage-managed-overage"))
            if(s.retainedWarning) Text("保留用量已达到提醒额度 ${Formatter.formatShortFileSize(context,s.policy.retainedWarningBytes)}。这仅为提醒，不会因此自动删除或拒绝保留；托管总额度和设备可用空间仍适用。",modifier=Modifier.testTag("storage-retained-warning"))
            Text("降低额度会回收可重建缓存。保留文件、待发送原件和正在使用的文件不会因此被删除。",style=MaterialTheme.typography.bodySmall)
            if(s.cacheOverLimit) Text("当前缓存仍超出额度，部分文件正在使用或等待清理",color=MaterialTheme.colorScheme.error)
            Text("已占用缓存额度：${Formatter.formatShortFileSize(context,s.cacheChargedBytes)}；临时传输预留：${Formatter.formatShortFileSize(context,s.temporaryReservedBytes)}",style=MaterialTheme.typography.bodySmall)
            OutlinedButton(preview,enabled=allowed,modifier=Modifier.testTag("storage-cleanup-preview")) {Text("检查可清理缓存")}
        }
        state.cleanupResult?.let {result->Text("已清理 ${result.deletedCount} 个文件，释放 ${Formatter.formatShortFileSize(context,result.releasedBytes)}；跳过 ${result.skippedCount} 个，失败 ${result.failedCount} 个。",Modifier.testTag("storage-cleanup-result"))}
        state.feedback?.let {Text(it,Modifier.testTag("storage-feedback"))}
        TextButton(refresh,enabled=allowed,modifier=Modifier.testTag("storage-refresh")) {Text("刷新存储状态")}
        TextButton(retention,enabled=allowed) {Text("管理失效资源保留")}
        TextButton(downloads,enabled=allowed) {Text("下载任务")}
    }
    state.cleanupPlan?.takeIf {allowed}?.let {plan->
        AlertDialog(onDismissRequest=dismiss,title={Text("清理本机缓存？")},text={Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text("预计清理 ${plan.fileCount} 个文件，释放 ${Formatter.formatShortFileSize(context,plan.estimatedBytes)}，跳过 ${plan.skippedCount} 个受保护文件。")
            Text("包括未完成下载留下的闲置临时文件。清理后可能需要重新下载，不删除消息或云端文件。")
            Text("预览有效期为 30 秒。确认时会再次检查，保留文件、待发送原件及新近使用的文件会跳过。")
        }},confirmButton={TextButton(confirm,modifier=Modifier.testTag("storage-cleanup-confirm")) {Text("清理本次缓存")}},
            dismissButton={TextButton(dismiss,modifier=Modifier.testTag("storage-cleanup-dismiss")) {Text("取消")}})
    }
}
