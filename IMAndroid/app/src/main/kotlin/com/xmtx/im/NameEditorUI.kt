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
import androidx.lifecycle.compose.currentStateAsState
import com.xmtx.im.client.*
import kotlinx.coroutines.launch

@Composable internal fun NameEditorScreen(target: NameTarget,state: AppState,active: Boolean,
    refresh: suspend (NameTarget) -> NameSnapshot?,save: suspend (NameSnapshot,String?) -> Boolean,
    retry: suspend (String) -> Unit,discard: suspend (String) -> Unit) {
    val session = state.session as? SessionUi.SignedIn ?: return
    val resumed = LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val allowed = active && resumed && !session.demo && (target as? NameTarget.Group)?.room !in state.snapshot.revokedRooms
    val cached = state.snapshot.nameSnapshots.firstOrNull { it.target == target && it.actor == session.user }
    val works = state.snapshot.nameOperations.filter { it.command.target == target && it.command.actor == session.user }
    val pending = works.any { !it.terminal }
    var draft by rememberSaveable(session.user.value,target.key) { mutableStateOf("") }
    var dirty by rememberSaveable(session.user.value,target.key) { mutableStateOf(false) }
    var baseline by remember(session.user,target) { mutableStateOf<NameSnapshot?>(null) }
    var refreshKey by remember { mutableIntStateOf(0) };var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session.user,target,allowed,refreshKey,state.snapshot.presentationGeneration) {
        baseline = null
        if(allowed) {
            val value = refresh(target)
            if(value != null) { baseline = value;if(!dirty) draft = value.name.orEmpty() }
        }
    }
    val fresh = baseline?.takeIf { it == cached }
    val normalized = runCatching { NameCommand.normalizedName(draft) }
    val editable = allowed && !busy && !pending && fresh != null
    LazyColumn(Modifier.fillMaxSize(),contentPadding = PaddingValues(20.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text(if(target is NameTarget.Contact) "备注仅你可见" else "群昵称在本群内展示",style = MaterialTheme.typography.titleMedium) }
        item { Text("留空可清除。最多 80 个 UTF-8 字节。",style = MaterialTheme.typography.bodySmall) }
        item { OutlinedTextField(draft,{ draft = it;dirty = true;notice = null },label = { Text(if(target is NameTarget.Contact) "私人备注" else "我的群昵称") },singleLine = true,
            isError = normalized.isFailure,enabled = allowed && !busy,modifier = Modifier.fillMaxWidth()) }
        if(fresh == null) item { Text(if(cached == null) "刷新当前名称后可保存" else "已保存名称：${cached.name ?: "未设置"}；请刷新后修改") }
        if(pending) item { Text("请先确认前一笔修改，再保存新的名称。") }
        item { Row {
            Button(onClick = { val value = fresh ?: return@Button;busy = true;scope.launch { try {
                if(save(value,normalized.getOrNull())) { dirty = false;baseline = null;notice = "修改已保存，正在确认结果" }
            } finally { busy = false } } },enabled = editable && normalized.isSuccess && normalized.getOrNull() != fresh?.name) { Text("保存") }
            TextButton(onClick = { refreshKey++ },enabled = allowed && !busy) { Text("刷新当前名称") }
        } }
        notice?.let { item { Text(it) } };state.error?.let { item { Text(it,color = MaterialTheme.colorScheme.error) } }
        items(works.reversed(),key = { it.command.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(work.command.name ?: "清除名称")
                Text(when(work.status) {
                    NameStatus.Pending -> if(work.closeRequested) "正在关闭原操作" else "正在确认修改结果"
                    NameStatus.NeedsAttention -> "结果尚未确认，请继续核对"
                    NameStatus.Committed -> "修改已确认"
                    NameStatus.Conflicted -> "版本已变化，请刷新后重新保存"
                    NameStatus.Rejected -> "修改被拒绝"
                    NameStatus.Closed -> "原操作已关闭"
                    NameStatus.Cancelled -> "尚未提交的修改已取消"
                })
                Row {
                    if(work.status == NameStatus.NeedsAttention) TextButton(onClick = { scope.launch { retry(work.command.operation) } },enabled = allowed && !busy) { Text("继续核对") }
                    if(!work.terminal && !work.closeRequested) TextButton(onClick = { scope.launch { discard(work.command.operation) } },enabled = allowed && !busy) { Text(if(work.submissionStarted) "关闭原操作" else "取消修改") }
                }
            } }
        }
    }
}
