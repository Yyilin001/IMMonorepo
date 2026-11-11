package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import android.text.format.Formatter
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

data class TransferConfirmation(val id:ResourceTransferId,val action:ResourceTransferAction,val displayName:String?,val preparation:ResourcePreparationCancellationPlan?=null,val unbound:ResourceUnboundCancellationPlan?=null) {
    init {require((action==ResourceTransferAction.CancelPreparation)==(preparation!=null));require(preparation==null || preparation.transfer==id);require((action==ResourceTransferAction.CancelUnbound)==(unbound!=null));require(unbound==null || unbound.transfer==id)}
}
data class ResourceTransfersState(val available:Boolean=false,val loading:Boolean=false,val group:ResourceTransferGroup=ResourceTransferGroup.Active,
    val page:ResourceTransferPage=ResourceTransferPage(persistentListOf()),val pageNumber:Int=1,val working:Boolean=false,
    val selected:PersistentList<ResourceTransferId>?=null,val confirmation:TransferConfirmation?=null,val result:ResourceTransferBatchResult?=null,val feedback:String?=null)

internal class ResourceTransfersController(parent:CoroutineScope,private val changes:Flow<Long>,
    private val read:suspend (ResourceTransferQuery)->ResourceTransferPage,
    private val control:suspend (ResourceTransferId,ResourceTransferAction)->Unit,
    private val batch:suspend (PersistentList<ResourceTransferId>,ResourceTransferAction)->ResourceTransferBatchResult,
    private val publish:(ResourceTransfersState)->Unit,
    private val previewPreparation:suspend (ResourceTransferId)->ResourcePreparationCancellationPlan={throw ResourceTransferActionUnavailable()},
    private val cancelPreparation:suspend (ResourcePreparationCancellationPlan)->ResourcePreparationCancellationResult={throw ResourceTransferActionUnavailable()},
    private val previewUnbound:suspend (ResourceTransferId)->ResourceUnboundCancellationPlan={throw ResourceTransferActionUnavailable()},
    private val cancelUnbound:suspend (ResourceUnboundCancellationPlan)->Unit={throw ResourceTransferActionUnavailable()},
    private val observations:StateFlow<ResourceTransferObservations> = MutableStateFlow(ResourceTransferObservations())) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceTransfersState();private set
    private var active=false;private var closed=false;private var epoch=0L;private var observer:Job?=null;private var command:Job?=null
    private var observationObserver:Job?=null
    private var rawPage=ResourceTransferPage(persistentListOf())
    private var cursors:PersistentList<ResourceTransferCursor?> = persistentListOf(null)
    private fun update(body:(ResourceTransfersState)->ResourceTransfersState) {if(!closed) {state=body(state);publish(state)}}
    private fun editable()=active && !closed && state.available && !state.loading && !state.working && state.confirmation==null
    fun foreground(value:Boolean) {
        if(closed || active==value) return
        active=value;epoch++;observer?.cancel();command?.cancel();observationObserver?.cancel();rawPage=ResourceTransferPage(persistentListOf());cursors=persistentListOf(null)
        update {ResourceTransfersState(group=it.group)}
        if(value) {
            observationObserver=scope.launch {observations.collect {snapshot->if(active && !closed) update {it.copy(page=rawPage.applyingObservations(snapshot))}}}
            reload()
        }
    }
    fun query(group:ResourceTransferGroup) {
        if(!active || closed || state.working || state.confirmation!=null || state.group==group) return
        cursors=persistentListOf(null);update {ResourceTransfersState(group=group)};reload()
    }
    fun page(next:Boolean) {
        if(!editable()) return
        if(next) {val cursor=state.page.next ?: return;cursors=cursors.add(cursor)} else {if(cursors.size==1) return;cursors=cursors.removeAt(cursors.lastIndex)}
        update {it.copy(pageNumber=cursors.size)};reload()
    }
    fun reload() {if(active && !closed && !state.working && state.confirmation==null) observe()}
    private fun observe(finishCommand:Boolean=false) {
        observer?.cancel();val e=++epoch;val query=ResourceTransferQuery(state.group,cursors.last())
        rawPage=ResourceTransferPage(persistentListOf())
        update {it.copy(page=rawPage,loading=true,available=false)}
        observer=scope.launch {changes.collectLatest {
            try {
                val page=read(query);ensureActive();if(active && !closed && e==epoch) rawPage=page
                if(active && !closed && e==epoch) update {current->current.copy(page=page.applyingObservations(observations.value),loading=false,available=true,working=if(finishCommand) false else current.working,
                    confirmation=current.confirmation?.takeIf {c->c.preparation!=null || page.entries.any {row->row.id==c.id && c.action in row.actions}})}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(active && !closed && e==epoch) {rawPage=ResourceTransferPage(persistentListOf());update {it.copy(page=rawPage,loading=false,available=false,working=false,confirmation=null,feedback="暂时无法读取传输任务，请刷新后重试")}}
            }
        }}
    }
    fun selectMode() {if(editable() && state.group==ResourceTransferGroup.Attention) update {it.copy(selected=if(it.selected==null) persistentListOf() else null,result=null,feedback=null)}}
    fun select(id:ResourceTransferId) {
        if(!editable() || state.page.entries.none {it.id==id}) return
        val selected=state.selected ?: return
        if(id in selected) update {it.copy(selected=selected.remove(id),result=null)}
        else if(selected.size<100) update {it.copy(selected=selected.add(id),result=null)}
    }
    fun selectPage() {if(editable() && state.selected!=null) update {it.copy(selected=it.page.entries.map {row->row.id}.toPersistentList(),result=null)}}
    fun act(id:ResourceTransferId,action:ResourceTransferAction) {
        if(!editable() || state.selected!=null) return
        val row=state.page.entries.firstOrNull {it.id==id && action in it.actions} ?: return
        if(action in setOf(ResourceTransferAction.CancelPreparation,ResourceTransferAction.CancelUnbound)) {prepare(row,action);return}
        if(action==ResourceTransferAction.Cancel) {update {it.copy(confirmation=TransferConfirmation(id,action,row.displayName))};return}
        execute {control(id,action);null}
    }
    private fun prepare(row:ManagedResourceTransfer,action:ResourceTransferAction) {
        observer?.cancel();val e=++epoch;update {it.copy(working=true,feedback=null,result=null)}
        command=scope.launch {
            try {
                val confirmation=if(action==ResourceTransferAction.CancelPreparation) {
                    val plan=previewPreparation(row.id);ensureActive();require(plan.transfer==row.id)
                    TransferConfirmation(row.id,action,row.displayName,preparation=plan)
                } else {
                    val plan=previewUnbound(row.id);ensureActive();require(plan.transfer==row.id)
                    TransferConfirmation(row.id,action,row.displayName,unbound=plan)
                }
                if(active && !closed && e==epoch) update {it.copy(confirmation=confirmation)}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(active && !closed && e==epoch) update {it.copy(feedback="任务状态已变化，无法生成取消预览，请刷新后检查")}
            } finally {if(active && !closed && e==epoch) observe(finishCommand=true)}
        }
    }
    fun dismiss() {if(!state.working) update {it.copy(confirmation=null)}}
    fun confirm() {
        if(!active || closed || !state.available || state.loading || state.working) return
        val confirmation=state.confirmation ?: return
        update {it.copy(confirmation=null)}
        val plan=confirmation.preparation
        if(confirmation.unbound!=null) execute("已请求取消未绑定任务，等待服务端确认") {cancelUnbound(confirmation.unbound);null}
        else if(plan==null) execute {control(confirmation.id,confirmation.action);null}
        else execute("已取消 ${plan.messageCount} 条待发送消息，未完成的传输将继续确认取消结果") {
            val result=cancelPreparation(plan);require(result.cancelledMessages==plan.messageCount);null
        }
    }
    fun retry(action:ResourceTransferAction) {
        if(!editable() || state.group!=ResourceTransferGroup.Attention || action !in setOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation)) return
        val ids=state.selected?.takeIf {it.isNotEmpty()} ?: return
        execute {batch(ids,action).also {require(it.action==action && it.items.map {item->item.id}==ids)}}
    }
    private fun execute(successFeedback:String="操作已请求",body:suspend ()->ResourceTransferBatchResult?) {
        observer?.cancel();val e=++epoch;update {it.copy(working=true,feedback=null,result=null)}
        command=scope.launch {
            try {
                val result=body();ensureActive()
                if(active && !closed && e==epoch) update {it.copy(result=result,selected=result?.failedIds ?: it.selected,feedback=if(result==null) successFeedback else null)}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(active && !closed && e==epoch) update {it.copy(feedback="任务状态已变化或结果未确认；已完成的操作会保留，请刷新后检查")}
            } finally {if(active && !closed && e==epoch) observe(finishCommand=true)}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ResourceTransfersState();cursors=persistentListOf(null)}
}

internal fun transferStatus(row:ManagedResourceTransfer)=row.waitingReason?.let {when(it) {
    ResourceTransferWaitingReason.Network->"等待网络"
    ResourceTransferWaitingReason.NetworkPolicy->"等待允许自动下载的网络"
    ResourceTransferWaitingReason.TransferSlot->"等待传输名额"
    ResourceTransferWaitingReason.RequestSlot->"等待请求名额"
    ResourceTransferWaitingReason.ServiceCooldown->"等待服务恢复额度"
}} ?: when(row.phase) {
    ResourceTransferPhase.Queued->"等待处理";ResourceTransferPhase.Preparing->"正在准备";ResourceTransferPhase.Transferring->"正在传输"
    ResourceTransferPhase.Confirming->"正在确认服务端状态";ResourceTransferPhase.Verifying->"正在校验";ResourceTransferPhase.Processing->"服务端处理中"
    ResourceTransferPhase.Pausing->"正在暂停，等待当前操作结束";ResourceTransferPhase.Paused->"已暂停";ResourceTransferPhase.Cancelling->"正在取消，等待确认"
    ResourceTransferPhase.WaitingRetry->"等待重试";ResourceTransferPhase.Completed->"已完成";ResourceTransferPhase.Cancelled->"已取消"
    ResourceTransferPhase.RequiresAttention,ResourceTransferPhase.Failed->when(row.failure) {
        ManagedResourceTransferFailure.CancellationUnconfirmed->"取消尚未确认，请重试取消";ManagedResourceTransferFailure.SourceUnavailable->"来源当前不可访问"
        ManagedResourceTransferFailure.Integrity->"文件校验失败";ManagedResourceTransferFailure.Storage->"本机存储暂不可用";ManagedResourceTransferFailure.Authorization->"需要重新确认访问权限"
        ManagedResourceTransferFailure.Rejected->"服务端未接受此资源";ManagedResourceTransferFailure.Expired->"任务已过期";else->"需要处理"
    }
}
private fun transferActionTitle(action:ResourceTransferAction)=when(action) {
    ResourceTransferAction.Retry->"重试";ResourceTransferAction.RetryCancellation->"重试取消";ResourceTransferAction.Pause->"暂停"
    ResourceTransferAction.Resume->"继续";ResourceTransferAction.Cancel->"取消下载";ResourceTransferAction.CancelUnbound->"取消未绑定任务";ResourceTransferAction.CancelPreparation->"取消相关待发送消息"
}
@Composable internal fun ResourceTransfersScreen(state:ResourceTransfersState,active:Boolean,demo:Boolean,query:(ResourceTransferGroup)->Unit,page:(Boolean)->Unit,
    reload:()->Unit,act:(ResourceTransferId,ResourceTransferAction)->Unit,selectMode:()->Unit,select:(ResourceTransferId)->Unit,selectPage:()->Unit,
    retry:(ResourceTransferAction)->Unit,confirm:()->Unit,dismiss:()->Unit,open:(ResourceKey)->Unit,related:(ResourceTransferId,ResourceUsage)->Unit,
    background:ResourceBackgroundState=ResourceBackgroundState.Unavailable,startBackground:()->Unit={},stopBackground:()->Unit={}) {
    val context=LocalContext.current
    val foreground=rememberReadForeground();val present=active && foreground && !demo
    val allowed=present && state.available && !state.loading && !state.working && state.confirmation==null
    var notificationDenied by remember {mutableStateOf(false)}
    val currentStart by rememberUpdatedState(startBackground)
    val currentPresent by rememberUpdatedState(present)
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {granted->
        notificationDenied=!granted
        if(granted && currentPresent) currentStart()
    }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal=16.dp).testTag("resource-transfers"),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item {Text(if(demo) "登录后可管理传输任务" else "上传、下载和服务端导入统一显示。应用在前台时处理任务，也可手动开启后台执行；暂停或取消须等待当前操作结束。",Modifier.padding(top=16.dp),style=MaterialTheme.typography.bodySmall)}
        if(!demo && background!=ResourceBackgroundState.Unavailable) item {
            OutlinedCard(Modifier.fillMaxWidth().testTag("resource-background")) {Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(when(background) {
                    ResourceBackgroundState.Starting->"正在启动后台传输"
                    ResourceBackgroundState.Running->"后台传输已开启"
                    ResourceBackgroundState.Stopping->"正在停止后台执行"
                    ResourceBackgroundState.Completed->"本次可执行的资源任务已处理"
                    ResourceBackgroundState.BudgetExpired->"本次后台执行时间已到"
                    ResourceBackgroundState.Stopped->"后台执行已停止"
                    ResourceBackgroundState.Failed->"后台执行未能继续，可重新开启"
                    else->"后台传输"
                },Modifier.testTag("resource-background-status"))
                Text("每次最多运行 15 分钟，并显示持续通知。停止后台执行不会取消任务；返回应用后继续确认消息和资料更改。应用被系统终止后，需要重新打开应用恢复任务。",style=MaterialTheme.typography.bodySmall)
                if(background.active) TextButton(stopBackground,enabled=present && background!=ResourceBackgroundState.Stopping,modifier=Modifier.testTag("resource-background-stop")) {Text("停止后台执行")}
                else TextButton({
                    notificationDenied=false
                    if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(context,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)
                        permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else startBackground()
                },enabled=allowed,modifier=Modifier.testTag("resource-background-start")) {Text("开启后台传输")}
                if(notificationDenied) Text("请允许通知后再开启后台传输。")
            }}
        }
        item {FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {ResourceTransferGroup.entries.forEach {group->
            FilterChip(state.group==group,{query(group)},enabled=present && !state.working && state.confirmation==null,label={Text(when(group) {ResourceTransferGroup.Active->"进行中";ResourceTransferGroup.Attention->"待处理";ResourceTransferGroup.Finished->"已结束"})},modifier=Modifier.testTag("transfers-group-${group.name}"))
        }}}
        if(state.loading || state.working) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        state.feedback?.let {item {Text(it,modifier=Modifier.testTag("transfers-feedback"))}}
        state.result?.let {result->item {Text("已请求 ${result.requestedCount} · 跳过 ${result.skippedCount} · 失败 ${result.failedIds.size}。失败项保留选中。",modifier=Modifier.testTag("transfers-result"))}}
        if(state.group==ResourceTransferGroup.Attention) item {
            FlowRow {TextButton(selectMode,enabled=allowed,modifier=Modifier.testTag("transfers-select-mode")) {Text(if(state.selected==null) "多选" else "结束多选")}
                if(state.selected!=null) {TextButton(selectPage,enabled=allowed) {Text("选择本页")};Text("已选 ${state.selected.size}/100",Modifier.padding(12.dp))}
            }
            if(state.selected!=null) FlowRow {
                for(action in listOf(ResourceTransferAction.Retry,ResourceTransferAction.RetryCancellation)) TextButton({retry(action)},enabled=allowed && state.selected.isNotEmpty(),modifier=Modifier.testTag("transfers-batch-${action.name}")) {Text(if(action==ResourceTransferAction.Retry) "重试所选传输" else "重试所选取消")}
                Text("仅处理支持该操作的任务；已暂停的任务需要单独继续。",style=MaterialTheme.typography.bodySmall)
            }
        }
        if(!state.loading && state.available && state.page.entries.isEmpty()) item {Text("此分类暂无任务")}
        items(state.page.entries,key={it.id.key}) {row->
            OutlinedCard(Modifier.fillMaxWidth().testTag("transfer-${row.id.key}")) {Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Row {if(state.selected!=null) Checkbox(row.id in state.selected,{select(row.id)},enabled=allowed,modifier=Modifier.testTag("transfer-select-${row.id.key}"))
                    Text(row.displayName ?: if(row.id.kind==ResourceTransferKind.Download) "来源当前不可访问" else "服务端导入",style=MaterialTheme.typography.titleMedium)}
                Text(when(row.id.kind) {ResourceTransferKind.Upload->"上传";ResourceTransferKind.Download->"下载";ResourceTransferKind.ServerImport->"服务端导入"}+" · "+transferStatus(row))
                row.waitingReason?.let {Text(when(it) {
                    ResourceTransferWaitingReason.Network->"自动下载意图已保留，网络恢复后继续原任务。"
                    ResourceTransferWaitingReason.NetworkPolicy->"当前网络不符合自动下载条件，可连接不受限的 Wi-Fi，或主动下载该文件。"
                    ResourceTransferWaitingReason.TransferSlot->"其他传输正在执行，名额释放后将继续。"
                    ResourceTransferWaitingReason.RequestSlot->"账号中的其他请求正在执行，无需重复点击。"
                    ResourceTransferWaitingReason.ServiceCooldown->"服务端冷却或重试额度尚未恢复，任务会按原计划继续。"
                },style=MaterialTheme.typography.bodySmall,modifier=Modifier.testTag("transfer-wait-${row.id.key}"))}
                row.totalBytes?.let {total->val size=Formatter.formatShortFileSize(context,total);Text(row.confirmedBytes?.let {"已确认 ${Formatter.formatShortFileSize(context,it)} / $size"} ?: "大小 $size",style=MaterialTheme.typography.bodySmall)}
                row.attemptProgress?.let {progress->
                    val label=if(row.id.kind==ResourceTransferKind.Download) "本段下载" else "本次上传"
                    LinearProgressIndicator(progress={progress.transferredBytes.toFloat()/progress.expectedBytes.toFloat()},modifier=Modifier.fillMaxWidth().semantics {contentDescription=label}.testTag("transfer-progress-${row.id.key}"))
                    Text("$label ${Formatter.formatShortFileSize(context,progress.transferredBytes)} / ${Formatter.formatShortFileSize(context,progress.expectedBytes)}",style=MaterialTheme.typography.bodySmall,modifier=Modifier.testTag("transfer-progress-label-${row.id.key}"))
                }
                FlowRow {row.actions.forEach {action->TextButton({act(row.id,action)},enabled=allowed && state.selected==null,modifier=Modifier.testTag("transfer-${action.name}-${row.id.key}")) {Text(transferActionTitle(action))}}}
                row.resource?.let {key->TextButton({open(key)},enabled=allowed) {Text("查看资源")}}
                if(row.hasBusinessOwners) row.usage?.let {usage->TextButton({related(row.id,usage)},enabled=allowed) {Text(when(usage) {is ResourceUsage.Attachment->"查看会话发送记录";ResourceUsage.UserAvatar->"查看相关资料更改";is ResourceUsage.GroupAvatar->"查看相关群头像更改"})}}
            }}
        }
        item {FlowRow {TextButton({page(false)},enabled=allowed && state.pageNumber>1) {Text("上一页")};Text("第 ${state.pageNumber} 页",Modifier.padding(12.dp));TextButton({page(true)},enabled=allowed && state.page.next!=null) {Text("下一页")};TextButton(reload,enabled=present && !state.working && state.confirmation==null) {Text("刷新传输任务")}}}
        item {Spacer(Modifier.height(16.dp))}
    }
    state.confirmation?.takeIf {present}?.let {value->AlertDialog(onDismissRequest=dismiss,modifier=Modifier.testTag("transfer-cancellation-confirmation"),title={Text(if(value.preparation==null) "取消此任务？" else "取消待发送消息？")},
        text={Text(value.preparation?.let {"将取消 ${it.messageCount} 条尚未交给发送队列的消息，并停止这些消息中所有未完成的资源准备。已准备完成的服务端资源不会随本次操作取消，本机文件仍按原策略管理。提交时会再次检查关联关系；若消息已进入发送队列，本次操作将被拒绝。"} ?: ((value.displayName?.let {"$it\n"} ?: "")+if(value.action==ResourceTransferAction.Cancel) "停止本机下载请求，不删除已经存在的缓存。" else "仅取消已预览且尚未完成、未绑定业务的资源任务。若任务已完成或被消息、资料或群头像使用，本次操作将被拒绝。取消结果需要服务端确认，本机来源会在确认后按原策略释放。"))},
        confirmButton={TextButton(confirm,enabled=state.available && !state.loading && !state.working,modifier=Modifier.testTag("transfer-confirm-cancel")) {Text("确认取消")}},dismissButton={TextButton(dismiss) {Text("返回")}})}
}
