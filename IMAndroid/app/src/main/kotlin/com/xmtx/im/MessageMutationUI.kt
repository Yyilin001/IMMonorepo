package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable internal fun WithdrawalConfirmation(prompt: WithdrawalPrompt?, confirm: suspend () -> Unit, dismiss: () -> Unit) {
    if(prompt == null) return
    val scope = rememberCoroutineScope()
    LaunchedEffect(prompt) {
        while(prompt.deadlineNanos - System.nanoTime() > 0) delay(((prompt.deadlineNanos - System.nanoTime()) / 1_000_000).coerceIn(1,30000))
        dismiss()
    }
    AlertDialog(onDismissRequest = dismiss, title = { Text("撤回消息？") }, text = { Text("撤回后对方将无法再看到此消息内容。确认在 30 秒内有效，消息版本变化后需要重新选择。") },
        confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认撤回") } }, dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable internal fun MessageEditorPage(room: RoomId,id: MessageId,state: AppState,model: AppViewModel,active: Boolean=true,
    openSources: (RoomId)->MessageSourceSession?=model::openMessageSources,
    save: suspend (RoomId,MessageId,Long,String)->Boolean=model::editMessage,back: ()->Unit) {
    val source=rememberMessageSources(room,persistentSetOf(id),state,active,openSources)
    val message=source.state.messages[id]
    var draft by rememberSaveable(room.value,id.value) {mutableStateOf("")}
    var revision by rememberSaveable(room.value,id.value) {mutableLongStateOf(0)}
    var original by rememberSaveable(room.value,id.value) {mutableStateOf("")}
    var initialized by rememberSaveable(room.value,id.value) {mutableStateOf(false)}
    var busy by remember {mutableStateOf(false)};val scope=rememberCoroutineScope()
    val foreground=rememberReadForeground()
    val actor=(state.session as? SessionUi.SignedIn)?.user
    val available=message!=null && message.sender==actor && room !in state.snapshot.revokedRooms
    LaunchedEffect(message,available) {
        if(!initialized && available) {
            draft=requireNotNull(message).text;original=draft;revision=message.revision;initialized=true
        }
    }
    val changed=initialized && message!=null && message.revision!=revision
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        if(source.state.loading) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
        source.state.feedback?.let {feedback->item {Text(feedback);TextButton(onClick=source.retry) {Text("重试读取消息")}}}
        if(!available && !source.state.loading) item {Text("消息当前不可编辑，草稿仍保留。",color=MaterialTheme.colorScheme.error)}
        if(initialized) {
            item {OutlinedTextField(draft,{draft=it},label={Text("消息内容")},minLines=6,enabled=!busy && active && foreground,modifier=Modifier.fillMaxWidth())}
            if(changed) item {Text("消息已有新版本。当前草稿未被覆盖，请查看最新内容后重新编辑。",color=MaterialTheme.colorScheme.error)}
            if(changed && available) item {TextButton(onClick={draft=requireNotNull(message).text;original=draft;revision=message.revision},enabled=!busy && active && foreground) {Text("载入最新消息")}}
            item {Text("${draft.toByteArray().size} / 65536 UTF-8 字节",style=MaterialTheme.typography.bodySmall)}
            item {Button(onClick={busy=true;scope.launch {try {if(save(room,id,revision,draft)) back()} finally {busy=false}}},
                enabled=active && foreground && available && !source.state.loading && !busy && !changed && draft.trim().isNotEmpty() && draft.trim()!=original && draft.trim().toByteArray().size<=65536) {Text(if(busy) "正在保存…" else "保存编辑")}}
        }
        state.error?.let {item {Text(it,color=MaterialTheme.colorScheme.error)}}
    }
}
@Composable internal fun MutationHistoryPage(room: RoomId,state: AppState,model: AppViewModel,active: Boolean=true,openSources: (RoomId)->MessageSourceSession?=model::openMessageSources) {
    val works = state.snapshot.mutationOperations.filter { it.command.room == room }.reversed()
    val scope = rememberCoroutineScope()
    val list=androidx.compose.foundation.lazy.rememberLazyListState()
    val ids=visibleMessageSourceIds(list,works.associate {it.command.operation to it.command.message}.toPersistentMap())
    val sources=rememberMessageSources(room,ids,state,active,openSources)
    LazyColumn(Modifier.fillMaxSize(),state=list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(works.isEmpty()) item { Text("暂无消息操作") }
        items(works, key = { it.command.operation }) { work ->
            var busy by remember { mutableStateOf(false) }
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(if(work.command.text == null) "撤回消息" else "编辑消息", style = MaterialTheme.typography.titleMedium)
                val visible = sources.state.messages.containsKey(work.command.message)
                if(visible) work.command.text?.let { Text(it.take(240), maxLines = 3) }
                Text(when(work.status) {
                    MutationStatus.Pending -> "请求已保存，正在确认结果"
                    MutationStatus.NeedsAttention -> "结果尚未确认，请继续核对原操作"
                    MutationStatus.Committed -> "操作已确认，正文以聊天同步结果为准"
                    MutationStatus.Conflicted -> "消息版本已变化，请同步后重新编辑"
                    MutationStatus.Rejected -> when(work.reason) { "alreadyWithdrawn" -> "消息已撤回"; "permissionDenied" -> "当前无权修改这条消息"; "expiredUnsubmitted" -> "提交窗口已过期"; else -> "操作被拒绝，请查看最新消息" }
                    MutationStatus.Closed -> "原操作已关闭"
                }, style = MaterialTheme.typography.bodySmall)
                if(work.status == MutationStatus.NeedsAttention) TextButton(onClick = { busy = true; scope.launch { try { model.retryMutation(work.command.operation) } finally { busy = false } } }, enabled = !busy) { Text("继续核对") }
            } }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
