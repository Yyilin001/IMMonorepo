package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Immutable data class MessageModerationPrompt(val room: RoomId,val message: MessageId,val messageRevision: Long,val membershipRevision: Long,
    val preview: String,val confirmation: ModerationConfirmation?,val deadlineNanos: Long)
@Composable internal fun MessageModerationConfirmationDialog(prompt: MessageModerationPrompt?,confirm: suspend () -> Unit,dismiss: () -> Unit) {
    if(prompt == null) return
    val scope = rememberCoroutineScope()
    LaunchedEffect(prompt) { while(prompt.deadlineNanos > System.nanoTime()) delay(((prompt.deadlineNanos-System.nanoTime())/1000000).coerceIn(1,30000));dismiss() }
    AlertDialog(onDismissRequest = dismiss,title = { Text("审核移除这条消息？") },text = { Text("${prompt.preview}\n\n将移除消息内容并保留审核记录。此操作无法撤销。") },
        confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认审核移除") } },dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable internal fun MessageModerationHistoryPage(room: RoomId,state: AppState,model: AppViewModel) {
    val scope = rememberCoroutineScope();var busy by remember { mutableStateOf(false) }
    val works = state.snapshot.moderationOperations.filter { it.intent.room == room }
    LazyColumn(Modifier.fillMaxSize(),contentPadding = PaddingValues(20.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("已确认的审核会按原消息版本核对；内容变化后需要重新选择消息。") }
        if(works.isEmpty()) item { Text("暂无消息审核记录") }
        items(works.reversed(),key = { it.intent.key }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                Text("消息 ${work.intent.message.value.takeLast(8)}",style = MaterialTheme.typography.titleSmall)
                Text(when(work.status) {
                    ModerationStatus.Pending -> "正在核对审核结果";ModerationStatus.NeedsAttention -> "结果尚未确定，请继续核对原操作"
                    ModerationStatus.Committed -> "审核完成，消息状态由同步更新";ModerationStatus.Conflicted -> "消息或成员版本已变化，请重新选择"
                    ModerationStatus.Rejected -> "审核未获允许，请刷新群状态";ModerationStatus.Closed -> "原请求已关闭，可重新选择消息"
                })
                if(work.status == ModerationStatus.NeedsAttention) TextButton(onClick = { busy = true;scope.launch { try { model.retryMessageModeration(work.intent.key) } finally { busy = false } } },enabled = !busy) { Text("继续核对原操作") }
            } }
        }
        state.error?.let { item { Text(it,color = MaterialTheme.colorScheme.error) } }
    }
}
