package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch

@Composable internal fun AnnouncementPage(room: RoomId, state: AppState, model: AppViewModel, active: Boolean) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(room, active, lifecycle) {
        if(active) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.loadMembers(room); awaitCancellation() }
    }
    val announcement = state.snapshot.announcements.firstOrNull { it.room == room }
    val revision = announcement?.revision ?: 0
    var draft by rememberSaveable(room.value) { mutableStateOf(announcement?.body.orEmpty()) }
    var draftRevision by rememberSaveable(room.value) { mutableLongStateOf(revision) }
    LaunchedEffect(revision, announcement?.body) {
        if(revision > draftRevision && announcement?.body == draft.trim()) draftRevision = revision
    }
    val directory = state.members?.takeIf { it.room == room }
    val canEdit = directory?.allows(GroupPermission.Announce) == true && room !in state.snapshot.revokedRooms
    val scope = rememberCoroutineScope(); var busy by remember { mutableStateOf(false) }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    val trimmed = draft.trim()
    LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Text("当前公告", style = MaterialTheme.typography.titleMedium) }
        item { Text(announcement?.body?.takeIf { it.isNotEmpty() } ?: "暂无群公告") }
        if(directory?.loading == true) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if(canEdit) {
            item { OutlinedTextField(draft, { draft = it }, label = { Text("编辑群公告") }, minLines = 4, maxLines = 12,
                supportingText = { Text("${trimmed.toByteArray().size} / 4096 字节") }, isError = trimmed.toByteArray().size > 4096, modifier = Modifier.fillMaxWidth()) }
            if(draftRevision != revision) item { Text("公告已有新版本。草稿已保留，请载入最新公告后再编辑。", color = MaterialTheme.colorScheme.error) }
            item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { act { model.prepareAnnouncement(room, trimmed, draftRevision) } }, enabled = !busy && draftRevision == revision && trimmed.isNotEmpty() && trimmed.toByteArray().size <= 4096 && trimmed != announcement?.body) { Text("发布公告") }
                OutlinedButton(onClick = { act { model.prepareAnnouncement(room, "", revision) } }, enabled = !busy && !announcement?.body.isNullOrEmpty()) { Text("清除公告") }
            } }
            item { TextButton(onClick = { draft = announcement?.body.orEmpty(); draftRevision = revision }, enabled = !busy) { Text("载入最新公告") } }
        }
        item { TextButton(onClick = { act { model.loadMembers(room) } }, enabled = !busy && directory?.loading != true) { Text("刷新权限") } }
        if(directory?.stale == true) item { Text(directory.error ?: "群状态需要刷新后才能修改公告。") }
        items(state.snapshot.capabilityOperations.filter { it.intent.room == room && it.status != GroupCapabilityStatus.DraftCancelled }, key = { it.intent.operation }) { work ->
            CapabilityWorkCard(work, directory?.stale == false && !directory.loading, busy,
                { act { model.reconfirmCapability(work) } }, { act { model.discardCapability(work.intent.operation) } }, { act { model.retryCapability(work.intent.operation) } })
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
@Composable internal fun PinsPage(room: RoomId, state: AppState, model: AppViewModel,active: Boolean=true,
    openSources: (RoomId)->MessageSourceSession?=model::openMessageSources,openMessage: (MessageId)->Unit={}) {
    val pins=state.snapshot.pins.filter {it.room==room}.sortedWith(compareByDescending<GroupPin> {it.sequence}.thenByDescending {it.message.value})
    val list=androidx.compose.foundation.lazy.rememberLazyListState()
    val ids=visibleMessageSourceIds(list,pins.associate {it.message.value to it.message}.toPersistentMap())
    val sources=rememberMessageSources(room,ids,state,active,openSources)
    val scope=rememberCoroutineScope();var busy by remember {mutableStateOf(false)}
    val allowed=active && rememberReadForeground() && room !in state.snapshot.revokedRooms
    LazyColumn(Modifier.fillMaxSize().testTag("pins-list"),state=list,contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        if(pins.isEmpty()) item {Text("暂无已同步的置顶消息")}
        sources.state.feedback?.let {item {Text(it);TextButton(sources.retry) {Text("重试读取消息")}}}
        items(pins,key={it.message.value}) {pin->
            val message=sources.state.messages[pin.message]
            Card(Modifier.fillMaxWidth().testTag("pin-${pin.message.value}")) {Column(Modifier.padding(16.dp)) {
                Text(message?.text ?: if(sources.state.loading) "正在读取消息…" else "消息内容当前不可用",maxLines=3,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                Row {
                    TextButton({openMessage(pin.message)},enabled=allowed && message!=null) {Text("打开聊天")}
                    TextButton({busy=true;scope.launch {try {model.preparePin(room,pin.message)} finally {busy=false}}},enabled=allowed && message!=null && !busy) {Text("管理此置顶")}
                }
            }}
        }
        items(state.snapshot.capabilityOperations.filter {it.intent.room==room && it.intent.action is GroupAction.Pin && it.status!=GroupCapabilityStatus.DraftCancelled},key={"work/${it.intent.operation}"}) {work->
            CapabilityWorkCard(work,state.members?.takeIf {it.room==room}?.stale==false,busy,
                {scope.launch {model.reconfirmCapability(work)}},{scope.launch {model.discardCapability(work.intent.operation)}},{scope.launch {model.retryCapability(work.intent.operation)}})
        }
        state.error?.let {item {Text(it,color=MaterialTheme.colorScheme.error)}}
    }
}
