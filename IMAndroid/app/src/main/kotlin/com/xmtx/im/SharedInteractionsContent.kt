package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.xmtx.im.sharedsdk.*

@Composable internal fun SharedMessageInteractions(state: SharedAppState, room: String, message: SharedMessage, model: SharedAppViewModel, forward: () -> Unit) {
    var replying by remember(message.id) { mutableStateOf(false) }
    var text by remember(message.id) { mutableStateOf("") }
    message.replyToID?.let { id ->
        TextButton({ model.openConversation(room, id) }, enabled = !state.busy && message.replyPreview != null, modifier = Modifier.testTag("shared_reply_reference_${message.id}")) {
            Text("回复：${message.replyPreview ?: "原消息已撤回或不可用"}")
        }
    }
    if (message.forwardedFromID != null) Text("转发的消息", modifier = Modifier.testTag("shared_forwarded_${message.id}"))
    if (!message.withdrawn) {
        Row {
            TextButton({ replying = true }, enabled = !state.busy, modifier = Modifier.testTag("shared_reply_${message.id}")) { Text("回复") }
            TextButton(forward, enabled = !state.busy, modifier = Modifier.testTag("shared_forward_${message.id}")) { Text("转发") }
        }
    }
    if (replying) AlertDialog(onDismissRequest = { if (!state.busy) replying = false }, title = { Text("回复消息") },
        text = { Column { Text(if (message.withdrawn) "原消息已撤回" else message.text.ifEmpty { "[附件]" }.take(160)); OutlinedTextField(text, { text = it }, modifier = Modifier.testTag("shared_reply_text")) } },
        confirmButton = { TextButton({ model.reply(room, message.id, text) { replying = false; text = "" } }, enabled = !state.busy && !message.withdrawn && text.isNotBlank(), modifier = Modifier.testTag("shared_reply_send")) { Text("发送回复") } },
        dismissButton = { TextButton({ replying = false }, enabled = !state.busy) { Text("取消") } })
}

@Composable internal fun SharedForwardContent(state: SharedAppState, model: SharedAppViewModel, room: String, message: String, revision: Long, back: () -> Unit) {
    var target by remember { mutableStateOf<SharedConversation?>(null) }
    LaunchedEffect(Unit) { model.firstConversations() }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_forward_targets")) {
        item { TextButton(back) { Text("返回") }; Text("转发到会话", style = MaterialTheme.typography.titleLarge); Text("按选中时的消息版本转发；权限和发送结果由服务器确认。") }
        items(state.snapshot?.conversations ?: kotlinx.collections.immutable.persistentListOf(), key = { it.id }) { row ->
            ListItem(headlineContent = { Text(row.title) }, modifier = Modifier.testTag("shared_forward_target_${row.id}").clickable(enabled = !state.busy) { target = row })
        }
        if (state.snapshot?.hasMoreConversations == true) item { TextButton(model::nextConversations, enabled = !state.busy, modifier = Modifier.testTag("shared_forward_next")) { Text("下一页会话") } }
        if (state.snapshot?.isFirstConversationPage == false) item { TextButton(model::firstConversations, enabled = !state.busy) { Text("返回最新会话") } }
    }
    target?.let { destination -> AlertDialog(onDismissRequest = { if (!state.busy) target = null }, title = { Text("确认转发") }, text = { Text("发送到 ${destination.title}") },
        confirmButton = { TextButton({ model.forward(room, message, revision, destination.id) { target = null; back() } }, enabled = !state.busy, modifier = Modifier.testTag("shared_forward_confirm")) { Text("转发") } },
        dismissButton = { TextButton({ target = null }, enabled = !state.busy) { Text("取消") } }) }
}

@Composable internal fun SharedInteractionWorkContent(state: SharedAppState, room: String, model: SharedAppViewModel) {
    val work = state.snapshot?.messaging?.takeIf { it.roomID == room }?.interactions ?: return
    work.forwards.forEach { row -> Column(Modifier.testTag("shared_forward_work_${row.id}")) {
        Text("转发：${interactionStatus(row.status)} · 成功 ${row.succeeded} / 拒绝 ${row.rejected} / 取消 ${row.cancelled} / 待确认 ${row.unresolved}")
        Row {
            if (row.retryable) TextButton({ model.retryForward(room, row.id) }, enabled = !state.busy) { Text("继续确认转发") }
            if (row.cancellable) TextButton({ model.cancelForward(room, row.id) }, enabled = !state.busy) { Text("取消剩余转发") }
        }
    } }
    if (work.failure != null) Text("消息操作暂不可用，请重新登录后重试")
}
private fun interactionStatus(value: String): String = when (value) {
    "committed" -> "已完成"; "rejected", "conflicted" -> "未成功，请重新确认消息"; "closed", "cancelledLocally" -> "已关闭"
    "expiredUnsubmitted" -> "未提交，已过期"; "paused", "needsAttention" -> "需要继续确认"; else -> "正在处理"
}
