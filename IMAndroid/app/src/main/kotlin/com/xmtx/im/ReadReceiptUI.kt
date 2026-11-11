package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentSetOf

@Composable internal fun rememberReadForeground(): Boolean {
    val owner = LocalLifecycleOwner.current
    var resumed by remember(owner) { mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _,_ -> resumed = owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) }
        owner.lifecycle.addObserver(observer);onDispose { owner.lifecycle.removeObserver(observer) }
    }
    return resumed
}
@Composable internal fun ReadHistoryPage(room: RoomId,state: AppState,retry: suspend (String)->Unit,archive: suspend (String)->Unit,restore: suspend (String)->Unit) {
    val scope = rememberCoroutineScope();var busy by remember { mutableStateOf(false) }
    val works = state.snapshot.readOperations.filter { it.command.room == room }
    LazyColumn(Modifier.fillMaxSize(),contentPadding = PaddingValues(20.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("这里追踪本机的阅读声明。停止追踪不代表服务端未记录，也不会撤销已经披露的已读状态。") }
        if(works.isEmpty()) item { Text("暂无已读记录") }
        items(works,key = { it.command.operation }) { work ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("阅读位置 ${work.command.sequence}",style = MaterialTheme.typography.titleSmall)
                Text(when(work.status) {
                    ReadStatus.Pending -> "等待确认"; ReadStatus.Archived -> "已停止本机追踪，结果仍可能已记录"
                    ReadStatus.Confirmed -> if(work.originalReceipt == true) "原操作已确认" else "服务端已读位置已满足此记录"
                    ReadStatus.NeedsAttention -> if(work.reason == "privacyPaused") "已按当前隐私设置暂停" else "需要继续确认"
                })
                fun act(block: suspend ()->Unit) { busy = true;scope.launch { try { block() } finally { busy = false } } }
                if(work.status == ReadStatus.NeedsAttention) {
                    TextButton(onClick = { act { retry(work.command.operation) } },enabled = !busy) { Text("继续确认") }
                    if(work.submissionStarted && (work.reason?.startsWith("currentUnavailable:") == true || work.control && work.reason == "controlCapacityRequired"))
                        TextButton(onClick = { act { archive(work.command.operation) } },enabled = !busy) { Text("停止本机追踪") }
                }
                if(work.status == ReadStatus.Archived) TextButton(onClick = { act { restore(work.command.operation) } },enabled = !busy) { Text("重新查询原记录") }
                HorizontalDivider()
            }
        }
        state.error?.let { error -> item { Text(error,color = MaterialTheme.colorScheme.error) } }
    }
}
@Composable internal fun ReadReadersScreen(room: RoomId,message: MessageId,state: AppState,session: SessionUi.SignedIn,active: Boolean,
    openProfiles: () -> ProfilePresentationPage? = { null },openSources: (RoomId)->MessageSourceSession?={null},fetch: suspend (RoomId,MessageId,String?)->ReadReadersPage) {
    val foreground = rememberReadForeground();val scope = rememberCoroutineScope()
    var page by remember(room,message) { mutableStateOf<ReadReadersPage?>(null) }
    var earlier by remember(room,message) { mutableStateOf(false) }
    var error by remember(room,message) { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var job by remember { mutableStateOf<Job?>(null) };var generation by remember { mutableLongStateOf(0) }
    val sources=rememberMessageSources(room,persistentSetOf(message),state,active,openSources)
    val source=sources.state.messages[message]
    val allowed = active && foreground && !session.demo && room !in state.snapshot.revokedRooms && source?.sender == session.user && source?.withdrawn == false
    val currentFetch by rememberUpdatedState(fetch)
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val keys = visibleProfileKeys(list,page?.readers ?: persistentListOf(),ProfileContext.Room(room))
    val profiles = rememberProfilePresentation(keys,state.snapshot.presentationGeneration,allowed,session.user,openProfiles,avatars=true)
    fun load(reset: Boolean) {
        val request = ++generation;val previous = job
        if(reset) { page = null;earlier = false }
        busy = true
        job = scope.launch {
            try {
                previous?.cancelAndJoin()
                if(request != generation) return@launch
                val cursor = if(reset) null else page?.nextCursor
                val received = currentFetch(room,message,cursor)
                ensureActive();if(request != generation) return@launch
                require(received.room == room && received.message == message && received.readers.size <= 100 && (received.nextCursor == null || received.nextCursor != cursor))
                val old = if(reset) null else page
                require(old == null || old.readers.none { it in received.readers })
                val all = (old?.readers?.addAll(received.readers) ?: received.readers)
                if(all.size > 1000) earlier = true
                page = received.copy(readers = all.takeLast(1000).toPersistentList());error = null
            } catch(e: CancellationException) { throw e }
            catch(_: Exception) { if(request == generation) error = "无法读取已读详情，请刷新重试" }
            finally { if(request == generation) busy = false }
        }
    }
    LaunchedEffect(allowed,source?.revision) {
        if(allowed) load(true) else { generation++;job?.cancelAndJoin();job = null;page = null;error = null;busy = false }
    }
    Column(Modifier.fillMaxSize().padding(20.dp),verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("仅显示服务端当前允许披露的已读成员，人数不代表全部阅读者。")
        if(sources.state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        sources.state.feedback?.let {Text(it);TextButton(onClick=sources.retry) {Text("重试读取消息")}}
        if(!allowed) Text("当前无法查看此消息的已读详情")
        else {
            if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            page?.let { Text("已加载 ${it.readers.size} 位已读成员") }
            if(earlier) Text("仅保留最近加载的 1000 位成员，请刷新重新查看。")
            error?.let { Text(it,color = MaterialTheme.colorScheme.error) }
            TextButton(onClick = { load(true) },enabled = !busy) { Text("刷新已读详情") }
            if(page?.nextCursor != null) TextButton(onClick = { load(false) },enabled = !busy) { Text("加载更多已读成员") }
            LazyColumn(Modifier.weight(1f).testTag("readers-list"),state = list,verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(page?.readers ?: persistentListOf(),key = { it.value }) { reader ->
                    val name=profiles.name(reader,ProfileContext.Room(room))
                    ListItem(headlineContent = { Text(name) },leadingContent = { Avatar(name,44,profiles.avatars[ProfileKey(reader,ProfileContext.Room(room))]) })
                }
            }
        }
    }
}
