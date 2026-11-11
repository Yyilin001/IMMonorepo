package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class ResourceBusinessSelection(val transfer:ResourceTransferId,val profile:String?=null)
data class ResourceBusinessState(val selection:ResourceBusinessSelection,val page:ResourceBusinessOwnerPage=ResourceBusinessOwnerPage(persistentListOf()),
    val profile:ProfileIntentStatus?=null,val pageNumber:Int=1,val available:Boolean=false,val loading:Boolean=false,val working:Boolean=false,
    val opened:ResourceBusinessOwner?=null,val disposition:ResourceProfileDispositionPlan?=null,val feedback:String?=null)

internal class ResourceBusinessController(val selection:ResourceBusinessSelection,parent:CoroutineScope,private val changes:Flow<Long>,
    private val read:suspend (ResourceBusinessOwnerQuery)->ResourceBusinessOwnerPage,
    private val contains:suspend (ResourceBusinessOwner)->Boolean,private val profile:suspend ()->ProfileIntentStatus?,
    private val resumeProfile:suspend ()->ResourceBusinessOwner.Profile?,private val preview:suspend ()->ResourceProfileDispositionPlan,
    private val dispose:suspend (ResourceProfileDispositionPlan)->Unit,private val publish:(ResourceBusinessState)->Unit) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceBusinessState(selection);private set
    private var active=false;private var closed=false;private var epoch=0L;private var observer:Job?=null;private var command:Job?=null
    private var cursors:PersistentList<ResourceBusinessOwnerCursor?> = persistentListOf(null)
    private fun update(body:(ResourceBusinessState)->ResourceBusinessState) {if(!closed) {state=body(state);publish(state)}}
    private fun allowed()=active && !closed && state.available && !state.loading && !state.working && state.disposition==null && state.opened==null
    fun foreground(value:Boolean) {
        if(closed || active==value) return
        active=value;epoch++;observer?.cancel();command?.cancel();cursors=persistentListOf(null);update {ResourceBusinessState(selection)}
        if(value) observe()
    }
    fun reload() {if(active && !closed && !state.working && state.disposition==null) observe()}
    fun page(next:Boolean) {
        if(!allowed() || selection.profile!=null) return
        if(next) cursors=cursors.add(state.page.next ?: return) else {if(cursors.size==1) return;cursors=cursors.removeAt(cursors.lastIndex)}
        update {it.copy(pageNumber=cursors.size)};observe()
    }
    private fun observe(finish:Boolean=false) {
        observer?.cancel();val e=++epoch;val query=ResourceBusinessOwnerQuery(selection.transfer,cursors.last())
        update {it.copy(available=false,loading=true)}
        observer=scope.launch {changes.collectLatest {
            try {
                val page=if(selection.profile==null) read(query) else ResourceBusinessOwnerPage(persistentListOf())
                val value=if(selection.profile!=null) profile() else null
                require(value==null || value.intent.id==selection.profile);ensureActive()
                if(active && !closed && e==epoch) update {it.copy(page=page,profile=value,available=true,loading=false,working=if(finish) false else it.working,
                    disposition=it.disposition.takeIf {_ -> value!=null && value==it.profile})}
            } catch(error:CancellationException) {throw error} catch(_:Exception) {
                if(active && !closed && e==epoch) update {it.copy(page=ResourceBusinessOwnerPage(persistentListOf()),profile=null,available=false,loading=false,working=false,opened=null,disposition=null,feedback="暂时无法读取相关更改，请刷新后重试")}
            }
        }}
    }
    fun open(owner:ResourceBusinessOwner) {
        if(!allowed() || state.page.entries.none {it.owner==owner}) return
        perform {check(contains(owner));ensureActive();update {it.copy(opened=owner)}}
    }
    fun opened() {update {it.copy(opened=null)}}
    fun resume() {
        val value=state.profile ?: return
        if(!allowed() || !value.sourceRetained || value.phase !in setOf(ProfileIntentPhase.NeedsAttention,ProfileIntentPhase.Closed)) return
        perform {val next=resumeProfile();ensureActive();update {it.copy(opened=next?.takeIf {it.id!=selection.profile},feedback="已继续处理，请查看更改状态；新资源任务可返回传输列表查看")}}
    }
    fun review() {
        val value=state.profile ?: return
        if(!allowed() || !value.sourceRetained || value.work?.terminal==false) return
        perform {
            val plan=preview();ensureActive();require(plan.transfer==selection.transfer && plan.intent==selection.profile)
            update {it.copy(disposition=plan)}
        }
    }
    fun dismiss() {if(!state.working) update {it.copy(disposition=null)}}
    fun confirm() {
        if(!active || closed || !state.available || state.loading || state.working) return
        val plan=state.disposition ?: return;update {it.copy(disposition=null)}
        perform {dispose(plan);ensureActive();update {it.copy(feedback=if(plan.effect==ResourceProfileDispositionEffect.WithdrawUnsubmittedChange) "已放弃此次资料更改" else "已解除此次更改的资源关联，已生效资料保持不变")}}
    }
    private fun perform(body:suspend CoroutineScope.()->Unit) {
        observer?.cancel();val e=++epoch;update {it.copy(working=true,feedback=null)}
        command=scope.launch {
            try {body();ensureActive()}
            catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(active && !closed && e==epoch) update {it.copy(opened=null,disposition=null,feedback="关联或更改状态已变化，请刷新后检查；已提交的操作会保留")}}
            finally {if(active && !closed && e==epoch) observe(finish=true)}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ResourceBusinessState(selection)}
}

@Composable internal fun ResourceBusinessScreen(state:ResourceBusinessState,active:Boolean,demo:Boolean,page:(Boolean)->Unit,reload:()->Unit,
    open:(ResourceBusinessOwner)->Unit,resume:()->Unit,review:()->Unit,confirm:()->Unit,dismiss:()->Unit,opened:()->Unit,navigate:(ResourceBusinessOwner)->Unit) {
    val foreground=rememberReadForeground();val present=active && foreground && !demo
    val allowed=present && state.available && !state.loading && !state.working && state.disposition==null && state.opened==null
    LaunchedEffect(state.opened,present) {if(present) state.opened?.let {opened();navigate(it)}}
    LazyColumn(Modifier.fillMaxSize().testTag("resource-business-page"),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        if(demo) item {Text("登录后可处理资源关联的更改")}
        if(state.loading || state.working) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        if(state.selection.profile==null) {
            item {Text("这里只显示仍持有此资源的资料或群头像更改。打开具体更改后，可查看状态或处理保留的来源。")}
            items(state.page.entries,key={it.owner.key}) {entry->OutlinedCard(Modifier.fillMaxWidth()) {Column(Modifier.padding(16.dp)) {
                Text(if(entry.owner is ResourceBusinessOwner.Profile) "个人资料更改" else "群头像更改",style=MaterialTheme.typography.titleMedium)
                Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(entry.createdAt)),style=MaterialTheme.typography.bodySmall)
                TextButton({open(entry.owner)},enabled=allowed,modifier=Modifier.testTag("resource-owner-${entry.owner.key}")) {Text("处理这次更改")}
            }}}
            if(state.available && state.page.entries.isEmpty()) item {Text("相关更改已处理")}
            item {Row {TextButton({page(false)},enabled=allowed && state.pageNumber>1) {Text("上一页")};Text("第 ${state.pageNumber} 页",Modifier.padding(12.dp));TextButton({page(true)},enabled=allowed && state.page.next!=null) {Text("下一页")}}}
        } else {
            state.profile?.let {value->
                item {Text("本次资料更改",style=MaterialTheme.typography.titleMedium);value.intent.name?.let {Text("昵称：$it")};Text(value.intent.upload?.displayName ?: "头像：使用已有资源")}
                item {Text(when(value.phase) {ProfileIntentPhase.PreparingAvatar->"头像准备中，资料尚未提交";ProfileIntentPhase.WaitingToSubmit->"等待提交";ProfileIntentPhase.Confirming->"正在确认原更改";ProfileIntentPhase.Committed->"更改已生效";ProfileIntentPhase.NeedsAttention->"需要处理";ProfileIntentPhase.Closed->"原更改已结束"},Modifier.testTag("resource-profile-status"))}
                if(value.sourceRetained && value.phase in setOf(ProfileIntentPhase.NeedsAttention,ProfileIntentPhase.Closed)) item {TextButton(resume,enabled=allowed,modifier=Modifier.testTag("resource-profile-resume")) {Text(if(value.canReplace) "重新应用此次更改" else "继续确认原更改")}}
                if(value.sourceRetained && value.work?.terminal!=false) item {TextButton(review,enabled=allowed,modifier=Modifier.testTag("resource-profile-dispose")) {Text(if(value.intent.frozen) "解除资源关联" else "放弃此次资料更改")}}
            }
            if(state.available && state.profile==null) item {Text("这次更改已处理或不再持有此资源")}
        }
        state.feedback?.let {item {Text(it,Modifier.testTag("resource-business-feedback"))}}
        item {TextButton(reload,enabled=present && !state.working && state.disposition==null) {Text("刷新相关更改")}}
    }
    state.disposition?.takeIf {present}?.let {plan->AlertDialog(onDismissRequest=dismiss,title={Text("处理本次资料更改？")},
        text={Text(if(plan.effect==ResourceProfileDispositionEffect.WithdrawUnsubmittedChange) "将整体放弃本次昵称与头像更改，已经生效的资料不会被修改。提交时会再次检查，若更改已进入结果确认阶段，本次操作将被拒绝。" else "解除本次更改的资源关联，不会撤销已经生效的资料。本机原件仍按存储策略管理。")},
        confirmButton={TextButton(confirm,enabled=state.available && !state.loading && !state.working,modifier=Modifier.testTag("resource-profile-confirm")) {Text("确认处理")}},
        dismissButton={TextButton(dismiss) {Text("继续保留")}})}
}
