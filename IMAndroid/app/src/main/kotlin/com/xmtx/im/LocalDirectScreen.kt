package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.launch

internal fun DirectConversationDestination.route(): Route = when (this) {
    is DirectConversationDestination.Room -> Route.Chat(room.value)
    is DirectConversationDestination.Pending -> Route.LocalDirect(operation)
}

@Composable internal fun LocalDirectScreen(operation: String, state: AppState, active: Boolean,
    send: suspend (LocalDirectMessage) -> Boolean, prepare: suspend () -> Unit,
    retry: suspend (String) -> DirectConversationDestination?, enter: suspend (String, String) -> RoomId?,
    initialDraft: String = "", navigate: (DirectConversationDestination, String) -> Unit) {
    val work = state.snapshot.directOperations.firstOrNull { it.command.operation == operation }
    val messages = state.snapshot.localDirectMessages.filter { it.operation == operation }
    var draft by rememberSaveable(operation) { mutableStateOf(initialDraft) }
    var pendingId by rememberSaveable(operation) { mutableStateOf<String?>(null) }
    var pendingText by rememberSaveable(operation) { mutableStateOf("") }
    var pendingTime by rememberSaveable(operation) { mutableLongStateOf(0) }
    var busy by remember(operation) { mutableStateOf(false) }
    var entering by remember(operation) { mutableStateOf(false) }
    var retryEntry by remember(operation) { mutableIntStateOf(0) }
    val foreground = rememberReadForeground()
    val enabled = active && foreground
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    LaunchedEffect(messages.lastOrNull()?.id, enabled) {
        if (enabled && messages.isNotEmpty()) list.animateScrollToItem(messages.lastIndex)
    }
    // A committed local save can outlive the caller's cancellation or recreation.
    LaunchedEffect(pendingId, messages, state.snapshot.sendIntents) {
        val id = pendingId ?: return@LaunchedEffect
        if (messages.any { it.id == id } || state.snapshot.sendIntents.any { it.intent.id == id }) {
            if (draft.trim() == pendingText) draft = ""
            pendingId = null; pendingText = ""
        }
    }
    LaunchedEffect(enabled, work, messages, pendingId, retryEntry) {
        if (!enabled || busy || pendingId != null || work?.status != DirectWorkStatus.Opened || messages.isNotEmpty()) return@LaunchedEffect
        entering = true
        try { enter(operation, draft)?.let { navigate(DirectConversationDestination.Room(it), "") } }
        finally { entering = false }
    }
    Column(Modifier.fillMaxSize().imePadding().testTag("local-direct-chat")) {
        Text(when (work?.status) {
            null -> "本地聊天请求已不可用"
            DirectWorkStatus.Pending -> "消息保存在本机，等待会话连接"
            DirectWorkStatus.NeedsAttention -> "会话连接需要重试，消息仍保存在本机"
            DirectWorkStatus.Rejected -> "服务器未允许创建会话，消息已保留"
            DirectWorkStatus.Closed -> "创建请求已关闭，消息已保留"
            DirectWorkStatus.Opened -> "会话已连接，正在准备消息"
        }, Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(messages, key = { it.id }) { message ->
                Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = MaterialTheme.shapes.large) {
                    Column(Modifier.fillMaxWidth().padding(14.dp)) {
                        Text(message.text)
                        Text("等待会话连接后发送", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
        state.error?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
        if (work != null && work.status != DirectWorkStatus.Pending) TextButton(onClick = {
            busy = true
            scope.launch { try {
                if (work.status == DirectWorkStatus.Opened) prepare()
                else retry(operation)?.let { navigate(it, draft) }
            } finally { busy = false; retryEntry++ } }
        }, enabled = enabled && !busy && !entering && pendingId == null, modifier = Modifier.testTag("local-direct-retry")) {
            Text(if (work.status == DirectWorkStatus.Opened) "继续进入聊天" else "重试连接")
        }
        Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(draft, { if (it.toByteArray(Charsets.UTF_8).size <= 65_536) draft = it },
                placeholder = { Text("发送消息…") }, maxLines = 4, enabled = enabled && !busy && !entering && pendingId == null && work != null,
                modifier = Modifier.weight(1f).testTag("local-direct-draft"))
            Button(onClick = {
                val message = if (pendingId != null) LocalDirectMessage(requireNotNull(pendingId), operation, pendingText, pendingTime)
                    else LocalDirectMessage.create(operation, draft).also { pendingId = it.id; pendingText = it.text; pendingTime = it.createdAt }
                busy = true
                scope.launch { try {
                    if (send(message)) { if (draft.trim() == message.text) draft = ""; pendingId = null; pendingText = "" }
                } finally { busy = false; retryEntry++ } }
            }, enabled = enabled && work != null && !busy && !entering && (pendingId != null || draft.isNotBlank()),
                modifier = Modifier.testTag("local-direct-send")) { Text(if (pendingId != null && !busy) "重试保存" else "发送") }
        }
    }
}
