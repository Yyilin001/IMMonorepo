package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.launch
import kotlinx.collections.immutable.*

@Composable internal fun MessageReactionsPage(room: RoomId,id: MessageId?,state: AppState,model: AppViewModel,active: Boolean=true,openSources: (RoomId)->MessageSourceSession?=model::openMessageSources) {
    val source=rememberMessageSources(room,id?.let {persistentSetOf(it)} ?: persistentSetOf(),state,active,openSources)
    val message=id?.let {source.state.messages[it]}
    val available = message != null && !message.withdrawn && message.delivery == Delivery.Accepted && message.revision > 0 && room !in state.snapshot.revokedRooms
    val works = state.snapshot.reactionOperations.filter { it.intent.room == room && (id == null || it.intent.message == id) }.reversed()
    val summaries = state.snapshot.reactions.filter { it.room == room && it.message == id }
    var custom by rememberSaveable(room.value, id?.value) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }; val scope = rememberCoroutineScope()
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    fun selected(key: String): Boolean = works.firstOrNull { it.intent.reaction == key && !it.terminal }?.intent?.present ?: summaries.any { it.reaction == key && it.own }
    val customKey = runCatching { normalizedReaction(custom) }.getOrNull()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(id != null) {
            if(source.state.loading) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
            source.state.feedback?.let {feedback->item {Text(feedback);TextButton(onClick=source.retry) {Text("重试读取消息")}}}
            if(available) {
                item { Text(requireNotNull(message).text.take(320), maxLines = 4, style = MaterialTheme.typography.bodyLarge) }
                item { Text("选择表情；再次选择可移除自己的反应。", style = MaterialTheme.typography.bodySmall) }
                items(listOf(listOf("👍", "❤️", "😂"), listOf("🎉", "😮", "🙏"))) { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { row.forEach { key ->
                        FilterChip(selected = selected(key), enabled = !busy && active && !source.state.loading, onClick = { act { model.changeReaction(room, requireNotNull(id), key, !selected(key)) } },
                            label = { Text(key, style = MaterialTheme.typography.headlineSmall) }, modifier = Modifier.semantics { contentDescription = "反应 $key" })
                    } }
                }
                item { OutlinedTextField(custom, { custom = it }, label = { Text("其他表情或短语") }, supportingText = { Text("最多 16 UTF-8 字节，不含空白") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
                item { TextButton(enabled = !busy && active && !source.state.loading && customKey != null, onClick = { act { model.changeReaction(room, requireNotNull(id), requireNotNull(customKey), !selected(customKey)) } }) { Text(if(customKey != null && selected(customKey)) "移除反应" else "添加反应") } }
                item { HorizontalDivider(); Text("已同步的反应", Modifier.padding(top = 12.dp), style = MaterialTheme.typography.titleMedium) }
                if(summaries.isEmpty()) item { Text("暂无已同步的反应") }
                items(summaries, key = { "summary-${it.reaction}" }) { summary ->
                    ListItem(headlineContent = { Text("${summary.reaction} ${summary.count}") }, supportingContent = { Text(if(summary.own) "你也参与了" else "来自聊天成员") },
                        trailingContent = { TextButton(enabled = !busy && active && !source.state.loading, onClick = { act { model.changeReaction(room, requireNotNull(id), summary.reaction, !selected(summary.reaction)) } }) { Text(if(selected(summary.reaction)) "移除" else "参与") } })
                }
            } else item { Text("消息当前不可用，无法修改反应。") }
        }
        item { Text("操作记录", style = MaterialTheme.typography.titleMedium) }
        if(works.isEmpty()) item { Text("暂无反应操作") }
        items(works, key = { it.intent.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${if(work.intent.present) "添加" else "移除"} ${work.intent.reaction}")
                Text(when(work.status) {
                    ReactionStatus.Draft -> "已保存选择，等待获取当前版本"
                    ReactionStatus.PreparationPaused -> "尚未提交，请重试获取当前版本"
                    ReactionStatus.Pending -> "正在确认反应操作"
                    ReactionStatus.NeedsAttention -> "结果尚未确认，请继续核对原操作"
                    ReactionStatus.Committed -> "操作已确认，计数以聊天同步结果为准"
                    ReactionStatus.Conflicted -> "反应版本已变化，请同步后重新选择"
                    ReactionStatus.Rejected -> when(work.reason) { "reactionLimitReached" -> "反应数量已达上限"; "messageWithdrawn" -> "消息已撤回"; "permissionDenied" -> "当前无权修改反应"; else -> "操作被拒绝，请查看最新消息" }
                    ReactionStatus.Closed -> "原操作已关闭"
                    ReactionStatus.Expired -> "尚未提交的选择已过期，请重新选择"
                    ReactionStatus.Cancelled -> "已取消"
                }, style = MaterialTheme.typography.bodySmall)
                Row {
                    if(work.status in setOf(ReactionStatus.PreparationPaused, ReactionStatus.NeedsAttention)) TextButton(enabled = !busy && active && !source.state.loading, onClick = { act { model.retryReaction(work.intent.operation) } }) { Text(if(work.command == null) "重试" else "继续核对") }
                    if(work.command == null && !work.terminal) TextButton(enabled = !busy && active && !source.state.loading, onClick = { act { model.discardReaction(work.intent.operation) } }) { Text("取消选择") }
                }
            } }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
