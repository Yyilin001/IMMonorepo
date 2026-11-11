package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.*

data class UnavailableRetentionState(val available:Boolean=false,val working:Boolean=false,
    val plan:ResourceUnavailableRetentionPlan?=null,val feedback:String?=null)

internal class UnavailableRetentionController(parent:CoroutineScope,
    private val preview:suspend ()->ResourceUnavailableRetentionPlan,
    private val commit:suspend (ResourceUnavailableRetentionPlan)->ResourceUnavailableRetentionResult,
    private val publish:(UnavailableRetentionState)->Unit) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=UnavailableRetentionState();private set
    private var closed=false;private var epoch=0L;private var job:Job?=null
    private fun update(value:UnavailableRetentionState) {if(!closed) {state=value;publish(value)}}
    fun foreground(value:Boolean) {
        if(closed || state.available==value) return
        epoch++;job?.cancel();update(UnavailableRetentionState(available=value))
    }
    fun dismiss() {if(!closed && !state.working) update(state.copy(plan=null))}
    fun prepare()=execute {
        val plan=preview();state.copy(working=false,plan=plan.takeIf {it.count>0},feedback=if(plan.count==0) "没有需要解除的失效保留" else null)
    }
    fun confirm() {
        val plan=state.plan ?: return
        execute {
            val result=commit(plan)
            state.copy(working=false,plan=null,feedback="已解除 ${result.releasedCount} 项保留，跳过 ${result.skippedCount} 项。未删除消息或文件。")
        }
    }
    private fun execute(body:suspend ()->UnavailableRetentionState) {
        if(closed || !state.available || state.working) return
        val e=epoch;update(state.copy(working=true,feedback=null))
        job=scope.launch {
            try {val result=body();ensureActive();if(!closed && state.available && e==epoch) update(result)}
            catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(!closed && state.available && e==epoch) update(state.copy(working=false,plan=null,feedback="预览已失效或暂时无法处理，请重新检查"))}
        }
    }
    fun close() {if(closed) return;closed=true;epoch++;scope.cancel();state=UnavailableRetentionState()}
}

@Composable internal fun UnavailableRetentionScreen(state:UnavailableRetentionState,active:Boolean,demo:Boolean,
    preview:()->Unit,confirm:()->Unit,dismiss:()->Unit) {
    val allowed=active && rememberReadForeground() && state.available && !demo
    Column(Modifier.fillMaxSize().padding(20.dp).testTag("unavailable-retention"),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        Text("解除当前不可访问资源的本机保留",style=MaterialTheme.typography.titleLarge)
        Text("只检查本机已保存的保留记录，不展示失效内容。解除保留不会删除消息、云端文件，也不会立即清理本机文件。")
        Text("操作前会显示本次数量，执行时恢复访问或重新保留的资源会跳过。",style=MaterialTheme.typography.bodyMedium)
        if(state.working) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.feedback?.let {Text(it,Modifier.testTag("retention-release-feedback"))}
        if(demo) Text("登录后可检查自己的保留记录")
        Button(preview,enabled=allowed && !state.working,modifier=Modifier.testTag("retention-release-preview")) {Text("检查失效保留")}
    }
    state.plan?.let {plan->
        AlertDialog(onDismissRequest={if(!state.working) dismiss()},title={Text("解除失效资源保留？")},text={
            Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("本次处理 ${plan.count} 项资源版本。预览有效期为 60 秒，执行时会重新检查。")
                if(plan.hasMore) Text("仍有更多记录，可完成后再次检查。")
                Text("只解除本机保留，不删除消息或文件。")
            }
        },confirmButton={TextButton(confirm,enabled=allowed && !state.working,modifier=Modifier.testTag("retention-release-confirm")) {Text("解除本次保留")}},
            dismissButton={TextButton(dismiss,enabled=!state.working) {Text("取消")}})
    }
}
