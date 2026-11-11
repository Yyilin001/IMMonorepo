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

data class ResourceDownloadsState(val available:Boolean=false,val loading:Boolean=false,val entries:PersistentList<ResourceDownloadSnapshot> = persistentListOf(),
    val working:String?=null,val feedback:String?=null,val network:ResourceDownloadNetworkPreferences?=null)

internal class ResourceDownloadsController(parent:CoroutineScope,private val changes:Flow<Long>,
    private val read:suspend ()->PersistentList<ResourceDownloadSnapshot>,private val control:suspend (String,ResourceDownloadControl)->Unit,
    private val publish:(ResourceDownloadsState)->Unit,
    private val readNetwork:suspend ()->ResourceDownloadNetworkPreferences?={null},
    private val writeNetwork:suspend (ResourceDownloadNetworkPreferences)->Unit={error("网络设置不可用")}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ResourceDownloadsState();private set
    private var active=false;private var closed=false;private var epoch=0L;private var observer:Job?=null;private var command:Job?=null
    private fun update(body:(ResourceDownloadsState)->ResourceDownloadsState) {if(!closed) {state=body(state);publish(state)}}
    fun foreground(value:Boolean) {
        if(closed || active==value) return
        active=value;epoch++;observer?.cancel();command?.cancel();update {it.copy(available=value,loading=false,entries=persistentListOf(),working=null,feedback=null,network=null)}
        if(value) reload()
    }
    fun reload() {
        if(!active || closed || state.working!=null) return
        observer?.cancel();val e=++epoch;update {it.copy(loading=true,feedback=null)}
        observer=scope.launch {changes.collectLatest {
            try {val rows=read();val network=readNetwork();ensureActive();if(active && !closed && e==epoch) update {it.copy(entries=rows,network=network,loading=false)}}
            catch(error:CancellationException) {throw error} catch(_:Exception) {if(active && !closed && e==epoch) update {it.copy(entries=persistentListOf(),network=null,loading=false,feedback="暂时无法读取下载任务，请重试")}}
        }}
    }
    fun act(id:String,action:ResourceDownloadControl) {
        if(!active || closed || state.loading || state.working!=null) return
        val row=state.entries.firstOrNull {it.work.id==id} ?: return
        if(!downloadAllows(row,action)) return
        val e=epoch;update {it.copy(working=id,feedback=null)}
        command=scope.launch {
            try {control(id,action);ensureActive()}
            catch(error:CancellationException) {throw error} catch(_:Exception) {if(active && !closed && e==epoch) update {it.copy(feedback="任务状态已变化，请刷新后重试")}}
            finally {if(active && !closed && e==epoch) update {it.copy(working=null)}}
        }
    }
    fun network(value:ResourceDownloadNetworkPreferences) {
        if(!active || closed || state.loading || state.working!=null || state.network==null || state.network==value) return
        val e=epoch;update {it.copy(working="network",feedback=null)}
        command=scope.launch {
            try {
                writeNetwork(value);val saved=readNetwork();ensureActive()
                if(active && !closed && e==epoch) update {it.copy(network=saved,feedback="下载网络设置已保存")}
            } catch(error:CancellationException) {throw error}
            catch(_:Exception) {if(active && !closed && e==epoch) update {it.copy(network=null,feedback="暂时无法更新网络设置，请刷新核对已保存的设置")}}
            finally {if(active && !closed && e==epoch) update {it.copy(working=null)}}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ResourceDownloadsState()}
}

internal fun downloadAllows(row:ResourceDownloadSnapshot,control:ResourceDownloadControl):Boolean {
    val w=row.work;if(w.terminal) return false
    return when(control) {
        ResourceDownloadControl.Cancel->w.control!=ResourceDownloadControl.Cancel
        ResourceDownloadControl.Pause->row.sourceAvailable && w.control==ResourceDownloadControl.Run && (w.requested || w.owner!=null)
        ResourceDownloadControl.Run->row.sourceAvailable && w.owner==null && !w.backgroundPending && w.control!=ResourceDownloadControl.Cancel && (w.control==ResourceDownloadControl.Pause || !w.requested)
    }
}
internal fun downloadStatus(work:ResourceDownloadWork)=when {
    work.phase==ResourceDownloadPhase.Completed->"下载完成"
    work.phase==ResourceDownloadPhase.Stopped->"已取消"
    work.control==ResourceDownloadControl.Cancel->"正在取消，等待传输结束"
    work.control==ResourceDownloadControl.Pause->if(work.owner==null && !work.backgroundPending) "已暂停" else "正在暂停，等待传输结束"
    work.backgroundPending->"等待系统传输及文件校验"
    work.owner!=null->"正在下载并校验"
    !work.requested->when(work.issue) {
        ResourceDownloadIssue.Unavailable->"来源当前不可访问"
        ResourceDownloadIssue.Authorization->"需要重新确认访问权限"
        ResourceDownloadIssue.Integrity->"文件校验失败，请重试"
        ResourceDownloadIssue.Policy->"当前网络不符合下载设置，请调整设置或切换网络后重试"
        ResourceDownloadIssue.Storage->"本机存储暂不可用，请检查空间后重试"
        else->"下载已暂停，需要重试"
    }
    maxOf(work.retryAt,work.serverRetryAt)>System.currentTimeMillis()->"等待重试"
    else->"等待下载"
}

@Composable internal fun ResourceDownloadsScreen(state:ResourceDownloadsState,active:Boolean,demo:Boolean,act:(String,ResourceDownloadControl)->Unit,reload:()->Unit,open:(ResourceKey)->Unit,network:(ResourceDownloadNetworkPreferences)->Unit={}) {
    val allowed=active && rememberReadForeground() && state.available && !demo
    LazyColumn(Modifier.fillMaxSize().padding(horizontal=16.dp).testTag("resource-downloads"),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        item {Text(if(demo) "登录后可管理下载任务" else "下载请求保存在本机，应用在前台时继续处理，也可在“传输任务”中开启后台处理。暂停或取消会等待正在进行的传输结束。",Modifier.padding(top=16.dp),style=MaterialTheme.typography.bodySmall)}
        state.network?.let {preferences->item {
            OutlinedCard(Modifier.fillMaxWidth().testTag("download-network-settings")) {
                Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text("原件下载网络",style=MaterialTheme.typography.titleMedium)
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                        Text("允许使用移动网络",Modifier.weight(1f))
                        Switch(preferences.allowsCellular,{network(preferences.copy(allowsCellular=it))},enabled=allowed && !state.loading && state.working==null,modifier=Modifier.testTag("download-cellular"))
                    }
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                        Text("允许在流量节省模式下下载",Modifier.weight(1f))
                        Switch(preferences.allowsConstrained,{network(preferences.copy(allowsConstrained=it))},enabled=allowed && !state.loading && state.working==null,modifier=Modifier.testTag("download-constrained"))
                    }
                    HorizontalDivider()
                    Text("自动下载原件",style=MaterialTheme.typography.titleSmall)
                    val policy=preferences.automaticDownloads
                    for(kinds in listOf(ResourceCategory.Image,ResourceCategory.Video,ResourceCategory.Audio,ResourceCategory.File).chunked(2)) {
                        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {for(kind in kinds) {
                            FilterChip(selected=kind in policy.categories,onClick={
                                val categories=if(kind in policy.categories) policy.categories.remove(kind) else policy.categories.add(kind)
                                network(preferences.copy(automaticDownloads=policy.copy(categories=categories)))
                            },label={Text(when(kind) {ResourceCategory.Image->"图片";ResourceCategory.Video->"视频";ResourceCategory.Audio->"音频";else->"文件"})},
                                enabled=allowed && !state.loading && state.working==null,modifier=Modifier.testTag("download-auto-${kind.name}"))
                        }}
                    }
                    var sizes by remember {mutableStateOf(false)}
                    Box {
                        TextButton({sizes=true},enabled=allowed && !state.loading && state.working==null,modifier=Modifier.testTag("download-auto-size")) {Text("每个文件上限：${policy.maximumByteCount/1024/1024} MB")}
                        DropdownMenu(sizes,{sizes=false}) {for(mb in listOf(10L,50L,100L,512L)) DropdownMenuItem(text={Text("$mb MB")},onClick={sizes=false;network(preferences.copy(automaticDownloads=policy.copy(maximumByteCount=mb*1024*1024)))},modifier=Modifier.testTag("download-auto-size-$mb"))}
                    }
                    Text("默认不自动下载。启用的类别仅在应用前台、非计费且非移动网络时新增任务；暂停或取消的任务不会自动重启。",style=MaterialTheme.typography.bodySmall)
                    Text("设置仅保存在此账号本机，用于新的原件下载和重试。收紧限制可能中止后台传输，现有缓存仍可读取。",style=MaterialTheme.typography.bodySmall)
                }
            }
        }}
        if(state.loading) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        state.feedback?.let {item {Text(it,color=MaterialTheme.colorScheme.error)}}
        if(!state.loading && state.entries.isEmpty()) item {Text("暂无下载任务")}
        items(state.entries,key={it.work.id}) {row->val work=row.work
            OutlinedCard(Modifier.fillMaxWidth().testTag("download-${work.id}")) {
                Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text(if(row.sourceAvailable) work.descriptor.displayName else "来源当前不可访问",style=MaterialTheme.typography.titleMedium)
                    if(work.automatic) Text("自动下载",style=MaterialTheme.typography.bodySmall)
                    Text(downloadStatus(work),modifier=Modifier.testTag("download-status-${work.id}"))
                    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        for(action in ResourceDownloadControl.entries) if(downloadAllows(row,action)) TextButton({act(work.id,action)},enabled=allowed && state.working==null,modifier=Modifier.testTag("download-${action.name}-${work.id}")) {
                            Text(when(action) {ResourceDownloadControl.Run->if(work.control==ResourceDownloadControl.Pause) "继续" else "重试";ResourceDownloadControl.Pause->"暂停";ResourceDownloadControl.Cancel->"取消下载"})
                        }
                    }
                    if(row.sourceAvailable) TextButton({open(work.descriptor.key)},enabled=allowed) {Text("查看资源")}
                }
            }
        }
        item {TextButton(reload,enabled=allowed && !state.loading && state.working==null) {Text("刷新下载任务")}}
    }
}
