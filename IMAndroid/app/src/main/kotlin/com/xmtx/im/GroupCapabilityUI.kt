package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Immutable data class CapabilityPrompt(val room: RoomId, val action: GroupAction, val confirmation: GroupCapabilityConfirmation?, val deadlineNanos: Long, val draft: String?)
internal val GroupAction.title get() = when(this) {
    is GroupAction.Pin -> if(pinned) "置顶消息" else "取消置顶"
    is GroupAction.Announcement -> if(body.isEmpty()) "清除群公告" else "更新群公告"
    is GroupAction.Permissions -> "更新${role.title}权限"
    is GroupAction.Role -> if(role == MemberRole.Admin) "设为管理员" else "设为普通成员"
    is GroupAction.Transfer -> "转让群主"
    is GroupAction.Dissolve -> "解散群聊"
}
internal val GroupPermission.title get() = when(this) {
    GroupPermission.Send -> "发送消息"; GroupPermission.Invite -> "邀请成员"; GroupPermission.Remove -> "移除成员"
    GroupPermission.ChangeRoles -> "管理角色与权限"; GroupPermission.Pin -> "管理置顶"; GroupPermission.Announce -> "管理群公告"
    GroupPermission.Moderate -> "管理消息"; GroupPermission.Mute -> "管理成员禁言"
}
@Composable internal fun CapabilityConfirmationDialog(prompt: CapabilityPrompt?, confirm: suspend () -> Unit, dismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    if(prompt == null) return
    LaunchedEffect(prompt) {
        while(prompt.deadlineNanos - System.nanoTime() > 0) delay(((prompt.deadlineNanos - System.nanoTime()) / 1_000_000).coerceIn(1, 30_000))
        dismiss()
    }
    val detail = when(val action = prompt.action) {
        is GroupAction.Role -> "用户 ${action.target.value.takeLast(8)} 将变为${action.role.title}。"
        is GroupAction.Transfer -> "用户 ${action.target.value.takeLast(8)} 将成为群主，你将成为普通成员。"
        is GroupAction.Dissolve -> "解散后所有成员都将失去群聊访问权限，此操作无法撤销。"
        is GroupAction.Permissions -> "${action.role.title}允许：${action.permissions.sortedBy { it.ordinal }.joinToString("、") { it.title }.ifEmpty { "无" }}。"
        is GroupAction.Pin -> if(action.pinned) "此消息将加入群置顶消息。" else "此消息将从群置顶消息中移除。"
        is GroupAction.Announcement -> if(action.body.isEmpty()) "将清除当前群公告。" else "新公告：${action.body.take(240)}${if(action.body.length > 240) "…" else ""}"
    }
    AlertDialog(onDismissRequest = dismiss, title = { Text("${prompt.action.title}？") }, text = { Text("$detail\n本次确认 30 秒内有效。群状态变化时需要重新确认。") },
        confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认") } }, dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable internal fun CapabilityWorkCard(work: GroupCapabilityWork, fresh: Boolean, busy: Boolean, reconfirm: () -> Unit, discard: () -> Unit, retry: () -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(work.intent.action.title, style = MaterialTheme.typography.titleSmall)
            Text(when(work.status) {
                GroupCapabilityStatus.DraftReady -> "已保存，正在核对操作权限"
                GroupCapabilityStatus.DraftPaused -> "尚未提交，请刷新群状态并重新确认"
                GroupCapabilityStatus.DraftCancelled -> "已取消"
                GroupCapabilityStatus.Pending -> "原命令等待确认，将自动继续"
                GroupCapabilityStatus.NeedsAttention -> "结果尚未确认，请继续核对原命令"
                GroupCapabilityStatus.Committed -> "操作成功，请刷新群状态"
                GroupCapabilityStatus.Rejected -> "操作未被允许，请刷新群状态后重试"
                GroupCapabilityStatus.Conflicted -> "版本已变化，未覆盖他人的修改"
                GroupCapabilityStatus.Closed -> "原请求已关闭，可重新操作"
            })
            Row {
                if(work.status == GroupCapabilityStatus.DraftPaused) TextButton(onClick = reconfirm, enabled = fresh && !busy) { Text("重新确认") }
                if(!work.terminal && work.admission == null) TextButton(onClick = discard, enabled = !busy) { Text("取消草稿") }
                if(work.status == GroupCapabilityStatus.NeedsAttention) TextButton(onClick = retry, enabled = !busy) { Text("继续核对") }
            }
        }
    }
}
private val PermissionSaver = Saver<PersistentSet<GroupPermission>, ArrayList<String>>(
    save = { ArrayList(it.map { permission -> permission.name }) }, restore = { it.map(GroupPermission::valueOf).toPersistentSet() })
@Composable internal fun GroupPoliciesPage(room: RoomId, state: AppState, model: AppViewModel, active: Boolean) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(room, active, lifecycle) {
        if(active) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.loadMembers(room); awaitCancellation() }
    }
    val directory = state.members?.takeIf { it.room == room }; val baseline = directory?.policies
    val scope = rememberCoroutineScope(); var busy by remember { mutableStateOf(false) }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    val recovery = state.snapshot.groupPolicyStates.firstOrNull { it.room == room }
    if(baseline == null) {
        Column(Modifier.padding(20.dp)) {
            PolicyRecoveryPanel(recovery,busy) { act { model.retryPolicyRecovery(room) } }
            Text(directory?.error ?: "正在读取群权限…")
            TextButton(onClick = { act { model.loadMembers(room) } }, enabled = !busy && directory?.loading != true) { Text("刷新权限") }
        }; return
    }
    var role by rememberSaveable(room.value) { mutableStateOf(MemberRole.Member) }
    var permissions by rememberSaveable(room.value, role, baseline.revision, stateSaver = PermissionSaver) { mutableStateOf(if(role == MemberRole.Admin) baseline.admin else baseline.member) }
    val fresh = !directory.stale && !directory.loading
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(recovery?.status in setOf(PolicyRecoveryStatus.Paused,PolicyRecoveryStatus.Pending,PolicyRecoveryStatus.WaitingForSync)) item { PolicyRecoveryPanel(recovery,busy,showPolicies = false) { act { model.retryPolicyRecovery(room) } } }
        item { Text("群主拥有全部权限；管理员和成员使用各自的明确权限集合。", style = MaterialTheme.typography.bodyMedium) }
        item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FilterChip(selected = role == MemberRole.Member, onClick = { role = MemberRole.Member }, label = { Text("普通成员") })
            FilterChip(selected = role == MemberRole.Admin, onClick = { role = MemberRole.Admin }, label = { Text("管理员") })
        } }
        if(!fresh) item { Text("请刷新权限后再修改；刷新将读取最新版本。") }
        items(GroupPermission.entries, key = { it.name }) { permission ->
            ListItem(headlineContent = { Text(permission.title) }, trailingContent = {
                Switch(checked = permission in permissions, onCheckedChange = { enabled -> permissions = if(enabled) permissions.add(permission) else permissions.remove(permission) },
                    enabled = !busy && directory.allows(GroupPermission.ChangeRoles), modifier = Modifier.semantics { contentDescription = permission.title })
            })
        }
        item { Button(onClick = { act { model.prepareCapability(room, GroupAction.Permissions(role, permissions, baseline.revision)) } },
            enabled = !busy && directory.allows(GroupPermission.ChangeRoles) && permissions != if(role == MemberRole.Admin) baseline.admin else baseline.member) { Text("保存权限") } }
        item { TextButton(onClick = { act { model.loadMembers(room) } }, enabled = !busy && !directory.loading) { Text("刷新权限") } }
        items(state.snapshot.capabilityOperations.filter { it.intent.room == room && it.status != GroupCapabilityStatus.DraftCancelled }, key = { it.intent.operation }) { work ->
            CapabilityWorkCard(work, fresh, busy, { act { model.reconfirmCapability(work) } }, { act { model.discardCapability(work.intent.operation) } }, { act { model.retryCapability(work.intent.operation) } })
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
