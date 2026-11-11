package com.xmtx.im

import androidx.compose.foundation.clickable
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

internal fun Contact.subtitle() = if (handle.isBlank()) id.value else "@$handle"
private fun ClientSnapshot.name(user: UserId) = contacts.firstOrNull { it.id == user }?.name ?: "用户 ${user.value.takeLast(8)}"
internal val SocialAction.title: String get() = when (this) {
    SocialAction.Request -> "添加朋友"; SocialAction.Accept -> "接受"; SocialAction.Reject -> "拒绝"
    SocialAction.Remove -> "解除关系"; SocialAction.Block -> "加入黑名单"; SocialAction.Unblock -> "移出黑名单"
}

@Composable internal fun SocialConfirmationDialog(prompt: SocialPrompt?, confirm: suspend () -> Unit, dismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    if (prompt == null) return
    LaunchedEffect(prompt) {
        while (prompt.deadlineNanos - System.nanoTime() > 0) delay(((prompt.deadlineNanos - System.nanoTime()) / 1_000_000).coerceIn(1, 30_000))
        dismiss()
    }
    AlertDialog(onDismissRequest = dismiss, title = { Text("${prompt.action.title}？") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("用户 ${prompt.target.value.takeLast(8)}")
            Text(when (prompt.action) {
                SocialAction.Block -> "将屏蔽此人的直接联系。"
                SocialAction.Unblock -> "解除对这个账号的屏蔽。"
                SocialAction.Remove -> if (prompt.relationship == RelationshipState.Pending) "取消尚未完成的好友申请。" else "解除与此人的好友关系。"
                SocialAction.Request -> "向此人发送好友申请。"
                SocialAction.Accept -> "接受此人的好友申请。"
                SocialAction.Reject -> "拒绝此人的好友申请。"
            })
            Text("本次确认在 30 秒后失效。", style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("暂不处理") } })
}

@Composable internal fun ProfileSocialActions(target: UserId, state: AppState, session: SessionUi.SignedIn,
    change: suspend (UserId, SocialAction) -> Unit) {
    if (target == session.user) return
    val relation = state.snapshot.relationships.firstOrNull { it.target == target }
    val blocked = state.snapshot.blockedUsers.any { it.target == target }
    Column {
        when (relation?.state) {
            null, RelationshipState.None -> SocialActionButton(target, SocialAction.Request, state, change)
            RelationshipState.Pending -> if (relation.requestedBy == session.user) {
                Text("已发送好友申请")
                SocialActionButton(target, SocialAction.Remove, state, change, "取消申请")
            } else Row {
                SocialActionButton(target, SocialAction.Accept, state, change)
                SocialActionButton(target, SocialAction.Reject, state, change)
            }
            RelationshipState.Accepted -> SocialActionButton(target, SocialAction.Remove, state, change, "移除好友")
        }
        SocialActionButton(target, if (blocked) SocialAction.Unblock else SocialAction.Block, state, change)
    }
}

@Composable internal fun SocialActionButton(target: UserId, action: SocialAction, state: AppState,
    change: suspend (UserId, SocialAction) -> Unit, label: String = action.title, enabled: Boolean = true) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    val pending = state.snapshot.socialOperations.any { !it.terminal && it.command.target == target && it.command.action.kind == action.kind }
    TextButton(onClick = { busy = true; scope.launch { try { change(target, action) } finally { busy = false } } }, enabled = enabled && !busy && !pending) {
        Text(if (busy) "处理中…" else if (pending) "等待操作确认" else label)
    }
}

@Composable internal fun SocialRequestOperations(state: AppState, active: Boolean,
    prepare: suspend (String) -> Unit, discard: suspend (String) -> Unit, retry: suspend (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (state.snapshot.socialProposals.isEmpty() && state.snapshot.socialOperations.isEmpty()) item { Text("暂无操作记录") }
        if (state.snapshot.socialProposals.isNotEmpty()) item { Text("尚未确认", style = MaterialTheme.typography.titleMedium) }
        items(state.snapshot.socialProposals, key = { "proposal/${it.id}" }) { proposal ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("${proposal.action.title} · ${state.snapshot.name(proposal.target)}")
                    Text("尚未提交，可继续确认或取消。", style = MaterialTheme.typography.bodySmall)
                    Row {
                        TextButton(onClick = { act { prepare(proposal.id) } }, enabled = active && !busy) { Text("继续确认") }
                        TextButton(onClick = { act { discard(proposal.id) } }, enabled = active && !busy) { Text("取消操作") }
                    }
                }
            }
        }
        if (state.snapshot.socialOperations.isNotEmpty()) item { Text("操作记录", style = MaterialTheme.typography.titleMedium) }
        items(state.snapshot.socialOperations, key = { "work/${it.command.operation}" }) { work ->
            ListItem(headlineContent = { Text("${work.command.action.title} · ${state.snapshot.name(work.command.target)}") },
                supportingContent = { Text(when (work.status) {
                    SocialWorkStatus.Pending -> "等待服务器确认，会自动重试"
                    SocialWorkStatus.NeedsAttention -> "结果尚未确认，请重试查询"
                    SocialWorkStatus.Committed -> "操作成功，关系状态由同步更新"
                    SocialWorkStatus.Conflicted -> "关系已发生变化，请查看当前状态后重新操作"
                    SocialWorkStatus.Closed -> "请求已关闭，可重新发起"
                    SocialWorkStatus.Rejected -> when (work.rejection) {
                        "firstSubmissionExpired" -> "请求已过期，可重新发起"
                        "invalidState" -> "当前关系不支持此操作"
                        "permissionDenied" -> "目前无法完成此操作"
                        else -> "服务器拒绝了这次请求"
                    }
                }) }, trailingContent = {
                    if (work.status == SocialWorkStatus.NeedsAttention) TextButton(onClick = { act { retry(work.command.operation) } }, enabled = active && !busy) { Text("重试") }
                })
        }
    }
}

@Composable internal fun BlockedUsersPage(state: AppState, change: suspend (UserId, SocialAction) -> Unit, push: (Route) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("黑名单", style = MaterialTheme.typography.titleMedium) }
        if (state.snapshot.blockedUsers.isEmpty()) item { Text("暂无已屏蔽的用户", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(state.snapshot.blockedUsers, key = { it.target.value }) { block ->
            ListItem(headlineContent = { Text(state.snapshot.name(block.target)) }, modifier = Modifier.clickable { push(Route.Profile(block.target.value)) },
                trailingContent = { SocialActionButton(block.target, SocialAction.Unblock, state, change) })
        }
        item { TextButton(onClick = { push(Route.Page(PageKind.Requests)) }) { Text("查看操作记录") } }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
