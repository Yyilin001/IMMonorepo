package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.xmtx.im.sharedsdk.*

@Composable internal fun SharedSearchContent(state: SharedAppState, model: SharedAppViewModel, room: String?, back: () -> Unit, open: (SharedSearchHit) -> Unit) {
    var query by remember(room) { mutableStateOf("") }
    val search = state.snapshot?.messaging?.search?.takeIf { it.roomID == room }
    LaunchedEffect(room) { model.searchMessages("", room) }
    DisposableEffect(Unit) { onDispose { model.clearMessaging() } }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(back) { Text("返回") }; Text(if (room == null) "搜索全部本地消息" else "搜索本会话", style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(query, { query = it }, label = { Text("关键词") }, modifier = Modifier.fillMaxWidth().testTag("shared_search_query"))
        Button({ model.searchMessages(query, room) }, enabled = !state.busy && query.isNotBlank(), modifier = Modifier.testTag("shared_search_submit")) { Text("搜索") }
        Text("仅搜索此设备已同步且仍有权限的消息")
        when (search?.status) {
            "building" -> Text("索引构建中，请稍后重新搜索")
            "failed", "unavailable", "refreshRequired" -> Text("结果已失效或暂不可用，请重新搜索")
            "ready" -> if (search.hits.isEmpty()) Text("没有匹配的消息")
        }
        LazyColumn(Modifier.weight(1f).testTag("shared_search_results")) {
            items(search?.hits ?: kotlinx.collections.immutable.persistentListOf(), key = { it.id }) { hit ->
                ListItem(headlineContent = { Text(hit.text) }, supportingContent = { Text(state.snapshot?.conversations?.firstOrNull { it.id == hit.roomID }?.title ?: "会话") },
                    modifier = Modifier.testTag("shared_search_hit_${hit.id}").clickable(enabled = !state.busy) { open(hit) })
            }
            if (search?.hasNext == true) item { TextButton(model::nextSearch, enabled = !state.busy, modifier = Modifier.testTag("shared_search_next")) { Text("下一页") } }
        }
    }
}
@Composable internal fun SharedReadersContent(state: SharedAppState, model: SharedAppViewModel, room: String, message: String, back: () -> Unit) {
    LaunchedEffect(room, message) { model.messageReaders(room, message) }
    DisposableEffect(Unit) { onDispose { model.clearMessaging() } }
    val now = sharedDisplayTime()
    val page = state.snapshot?.messaging?.readers?.takeIf { it.roomID == room && it.messageID == message && it.expiresAtElapsed > now }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_readers")) {
        item { TextButton(back) { Text("返回") }; Text("群消息已读详情", style = MaterialTheme.typography.titleLarge)
            Text("仅显示允许披露的阅读者；以下为用户 ID")
            TextButton({ model.messageReaders(room, message) }, enabled = !state.busy, modifier = Modifier.testTag("shared_readers_refresh")) { Text("刷新") } }
        if (page == null) item { Text("请刷新已读详情") }
        else if (page.users.isEmpty()) item { Text("暂无可披露的阅读者") }
        items(page?.users ?: kotlinx.collections.immutable.persistentListOf(), key = { it }) { user -> Text(user, modifier = Modifier.testTag("shared_reader_$user")) }
        if (page?.hasNext == true) item { TextButton({ model.messageReaders(room, message, true) }, enabled = !state.busy, modifier = Modifier.testTag("shared_readers_next")) { Text("下一页") } }
    }
}
@Composable internal fun SharedMessageActions(state: SharedAppState, room: String, message: SharedMessage, model: SharedAppViewModel, readers: () -> Unit) {
    var editing by remember(message.id) { mutableStateOf(false) }; var withdrawing by remember(message.id) { mutableStateOf(false) }
    var draft by remember(message.id) { mutableStateOf("") }; var original by remember(message.id) { mutableStateOf(message) }
    Row {
        if (message.senderID == state.snapshot?.userID && !message.withdrawn) Text(if (message.readByPeer) "已读" else "已发送", modifier = Modifier.testTag("shared_read_state_${message.id}"))
        if (message.canMutate) {
            TextButton({ original = message; draft = message.text; editing = true }, enabled = !state.busy, modifier = Modifier.testTag("shared_edit_${message.id}")) { Text("编辑") }
            TextButton({ original = message; withdrawing = true }, enabled = !state.busy, modifier = Modifier.testTag("shared_withdraw_${message.id}")) { Text("撤回") }
            if (state.snapshot?.messaging?.isGroup == true) TextButton(readers, enabled = !state.busy, modifier = Modifier.testTag("shared_readers_${message.id}")) { Text("已读详情") }
        }
    }
    if (editing) AlertDialog(onDismissRequest = { if (!state.busy) editing = false }, title = { Text("编辑消息") },
        text = { Column { OutlinedTextField(draft, { draft = it }, modifier = Modifier.testTag("shared_edit_text")); if (message.revision != original.revision) Text("消息已变化，请取消后重新编辑") } },
        confirmButton = { TextButton({ model.editMessage(room, original, draft) { editing = false } }, enabled = !state.busy && draft.isNotBlank() && message.revision == original.revision && message.canMutate, modifier = Modifier.testTag("shared_edit_confirm")) { Text("保存") } },
        dismissButton = { TextButton({ editing = false }, enabled = !state.busy) { Text("取消") } })
    if (withdrawing) AlertDialog(onDismissRequest = { if (!state.busy) withdrawing = false }, title = { Text("撤回这条消息？") }, text = { Text("撤回成功后，消息内容将不再显示。") },
        confirmButton = { TextButton({ model.withdrawMessage(room, original) { withdrawing = false } }, enabled = !state.busy && message.revision == original.revision && message.canMutate, modifier = Modifier.testTag("shared_withdraw_confirm")) { Text("撤回") } },
        dismissButton = { TextButton({ withdrawing = false }, enabled = !state.busy) { Text("取消") } })
}
@Composable internal fun SharedVisibleMessages(state: SharedAppState, room: String, list: LazyListState, model: SharedAppViewModel) {
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val current by rememberUpdatedState(state)
    LaunchedEffect(room, state.generation, list, lifecycle) {
        if (lifecycle != Lifecycle.State.RESUMED) return@LaunchedEffect
        var reported: List<String>? = null
        snapshotFlow {
            val ids = current.snapshot?.chat?.takeIf { it.roomID == room }?.messages?.map { it.id }?.toSet() ?: emptySet()
            val visible = list.layoutInfo.visibleItemsInfo.filter { it.offset < list.layoutInfo.viewportEndOffset && it.offset + it.size > list.layoutInfo.viewportStartOffset }
                .mapNotNull { (it.key as? String)?.takeIf(ids::contains) }
            Triple(visible, current.busy, current.reportingVisible)
        }.collect { (visible, busy, reporting) ->
            if (!busy && !reporting && visible != reported && model.markVisibleMessages(room, visible)) reported = visible
        }
    }
}
