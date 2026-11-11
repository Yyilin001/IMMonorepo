package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.toPersistentMap
import kotlinx.coroutines.launch

@Composable internal fun GroupsPage(state: AppState, retry: suspend (String) -> Unit, cancel: suspend (String) -> Unit, push: (Route) -> Unit,active: Boolean=true,openGroupAvatar: (RoomId)->GroupAvatarPage?={null}) {
    val list=androidx.compose.foundation.lazy.rememberLazyListState()
    val real=(state.session as? SessionUi.SignedIn)?.demo==false
    val rows=state.snapshot.conversations.filter { it.kind==RoomKind.Group && it.id !in state.snapshot.revokedRooms }.associate { "room/${it.id.value}" to it.id }.toPersistentMap()
    val visible=visibleGroupRooms(list,rows)
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var cancelling by remember { mutableStateOf<String?>(null) }
    LazyColumn(Modifier.fillMaxSize(),state=list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Button(onClick = { push(Route.Page(PageKind.CreateGroup)) }) { Text("新建群聊") } }
        item { OutlinedButton(onClick = { push(Route.Page(PageKind.JoinGroup)) }) { Text("通过邀请加入") } }
        if (state.snapshot.groupCreations.isNotEmpty()) item { Text("建群记录", style = MaterialTheme.typography.titleMedium) }
        items(state.snapshot.groupCreations, key = { "creation/${it.command.operation}" }) { work ->
            val progress = work.progress; val room = work.room
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(work.command.title, style = MaterialTheme.typography.titleMedium)
                    Text(when (work.status) {
                        GroupCreationStatus.Created -> "群聊已创建 · ${work.command.members.size + 1} 人"
                        GroupCreationStatus.Closed -> "建群已取消"
                        GroupCreationStatus.Rejected -> when (work.rejection) { "submissionExpired" -> "提交已过期，可以重新创建"; "invalidAudience" -> "部分成员无法加入，请重新选择"; else -> "目前无法创建此群聊" }
                        GroupCreationStatus.NeedsAttention -> "结果尚未确认，请继续核对"
                        GroupCreationStatus.Pending -> when {
                            work.cancellationRequested -> "正在核对取消结果；已创建的群不会被自动解散"
                            progress?.phase == GroupCreationPhase.Finalizing -> "正在创建 · 已完成 ${progress.copied}/${work.command.members.size + 1} 人"
                            progress != null -> "正在提交成员 · ${progress.accepted}/${work.command.members.size}"
                            else -> "等待提交，会自动继续"
                        }
                    })
                    Row {
                        if (room != null) TextButton(onClick = { push(Route.Chat(room.value)) }) { Text("打开群聊") }
                        if (work.status == GroupCreationStatus.NeedsAttention) TextButton(onClick = {
                            busy = true; scope.launch { try { retry(work.command.operation) } finally { busy = false } }
                        }, enabled = !busy) { Text("继续核对") }
                        if (!work.terminal && !work.cancellationRequested) TextButton(onClick = { cancelling = work.command.operation }, enabled = !busy) { Text("取消建群") }
                    }
                }
            }
        }
        item { Text("我的群聊", style = MaterialTheme.typography.titleMedium) }
        if (state.snapshot.conversations.none { it.kind == RoomKind.Group }) item { Text("暂无已同步的群聊") }
        items(state.snapshot.conversations.filter { it.kind == RoomKind.Group }, key = { "room/${it.id.value}" }) { room ->
            val image=rememberGroupAvatar(room.id,state.snapshot.groupAvatarGeneration,active && real && room.id in visible,openGroupAvatar).image
            ListItem(headlineContent = { Text(room.title) }, leadingContent={ Avatar(room.title,image=image) }, supportingContent = { Text(room.preview.ifBlank { "开始群聊吧" }) },
                modifier = Modifier.clickable { push(Route.Chat(room.id.value)) })
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
    cancelling?.let { id -> AlertDialog(onDismissRequest = { cancelling = null }, title = { Text("取消这次建群？") },
        text = { Text("将查询并尝试关闭原请求。如果群已经创建，会保留结果供你打开。") },
        confirmButton = { TextButton(onClick = { cancelling = null; busy = true; scope.launch { try { cancel(id) } finally { busy = false } } }) { Text("确认取消") } },
        dismissButton = { TextButton(onClick = { cancelling = null }) { Text("继续建群") } }) }
}

@Composable internal fun CreateGroupPage(state: AppState, session: SessionUi.SignedIn, active: Boolean,
    resolve: suspend (String) -> IdentityLookup?, create: suspend (String, PersistentList<UserId>) -> Boolean, back: () -> Unit) {
    var title by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var members by rememberSaveable(stateSaver = listSaver<PersistentList<UserId>, String>(save = { it.map { id -> id.value } }, restore = { it.map(UserId::invoke).toPersistentList() })) { mutableStateOf(persistentListOf<UserId>()) }
    var busy by remember { mutableStateOf(false) }
    var feedback by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableLongStateOf(0) }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val currentActive by rememberUpdatedState(active)
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) generation++ }
        lifecycle.addObserver(observer); onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(active) { if (!active) generation++ }
    val pending = state.snapshot.groupCreations.any { !it.terminal }
    val enabled = !busy && !pending
    LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { OutlinedTextField(title, { title = it }, label = { Text("群名称") }, singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth()) }
        item { Text("群成员（${members.size + 1}）", style = MaterialTheme.typography.titleMedium) }
        item { Text("你将自动加入群聊，也可以先创建只有自己的群聊。", style = MaterialTheme.typography.bodySmall) }
        if (state.snapshot.contacts.isNotEmpty()) item { Text("从好友中选择") }
        items(state.snapshot.contacts, key = { "friend/${it.id.value}" }) { contact ->
            ListItem(headlineContent = { Text(contact.name) }, supportingContent = { Text(contact.subtitle()) }, trailingContent = {
                Checkbox(checked = contact.id in members, enabled = enabled, onCheckedChange = { checked -> members = if (checked) members.add(contact.id) else members.filter { it != contact.id }.toPersistentList() })
            }, modifier = Modifier.clickable(enabled = enabled) { members = if (contact.id in members) members.filter { it != contact.id }.toPersistentList() else members.add(contact.id) })
        }
        item { OutlinedTextField(handle, { handle = it; generation++ }, label = { Text("通过公开标识添加成员") }, singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth()) }
        item { TextButton(onClick = {
            val requested = handle; val currentGeneration = generation
            busy = true; feedback = null
            scope.launch {
                try {
                    val result = resolve(requested)
                    if (currentGeneration == generation && currentActive && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && result?.valid() == true) {
                        val user = result.identity.user
                        if (user == session.user) feedback = "你已在群成员中"
                        else if (user in members) feedback = "该成员已选择"
                        else { members = members.add(user); handle = "" }
                    }
                } finally { busy = false }
            }
        }, enabled = enabled && handle.isNotBlank()) { Text("查找并添加") } }
        // The frozen selection stores identifiers only; discovery display names never become durable profile data.
        items(members.filter { id -> state.snapshot.contacts.none { it.id == id } }, key = { "selected/${it.value}" }) { user ->
            ListItem(headlineContent = { Text("已选用户 ${user.value.takeLast(8)}") }, trailingContent = {
                TextButton(onClick = { members = members.filter { it != user }.toPersistentList() }, enabled = enabled) { Text("移除") }
            })
        }
        feedback?.let { item { Text(it) } }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        if (pending) item { Text("已有建群请求正在确认，请返回群聊页查看进度。") }
        item { Button(onClick = {
            busy = true
            scope.launch { try { if (create(title, members)) { title = ""; members = persistentListOf(); back() } } finally { busy = false } }
        }, enabled = enabled && title.isNotBlank()) { Text(if (busy) "处理中…" else "创建群聊") } }
    }
}
