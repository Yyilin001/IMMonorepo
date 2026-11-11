package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Immutable data class MembersState(val room: RoomId, val revision: Long? = null, val actorRole: MemberRole? = null,
    val items: PersistentList<GroupMember> = persistentListOf(), val nextCursor: String? = null, val policies: GroupPolicies? = null,
    val stale: Boolean = true, val loading: Boolean = false, val earlier: Boolean = false, val error: String? = null, val administrationFeedback: String? = null) {
    fun allows(permission: GroupPermission) = !stale && !loading && actorRole?.let { policies?.allows(it, permission) } == true
}
@Immutable data class MemberPrompt(val room: RoomId, val target: UserId, val action: MembershipAction,
    val confirmation: MembershipConfirmation?, val deadlineNanos: Long, val draft: String? = null)
internal val MemberRole.title get() = when(this) { MemberRole.Owner -> "群主"; MemberRole.Admin -> "管理员"; MemberRole.Member -> "成员" }

@Composable internal fun MemberConfirmationDialog(prompt: MemberPrompt?, actor: UserId, confirm: suspend () -> Unit, dismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    if (prompt == null) return
    LaunchedEffect(prompt) {
        while (prompt.deadlineNanos - System.nanoTime() > 0) delay(((prompt.deadlineNanos - System.nanoTime()) / 1_000_000).coerceIn(1, 30_000))
        dismiss()
    }
    val action = if (prompt.action == MembershipAction.Add) "添加成员" else if (prompt.target == actor) "退出群聊" else "移除成员"
    AlertDialog(onDismissRequest = dismiss, title = { Text("$action？") },
        text = { Text("${if (prompt.target == actor) "你" else "用户 ${prompt.target.value.takeLast(8)}"} · 本次确认 30 秒内有效。成员状态变化时需要重新确认。") },
        confirmButton = { TextButton(onClick = { scope.launch { confirm() } }) { Text("确认") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
}
@Composable internal fun MembersPage(room: RoomId, state: AppState, session: SessionUi.SignedIn, model: AppViewModel, active: Boolean, openPolicies: () -> Unit, openAnnouncement: () -> Unit,
    openProfiles: () -> ProfilePresentationPage? = model::openProfiles,openProfile: (UserId)->Unit = {}) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    var handle by rememberSaveable(room.value) { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(room, active, lifecycle) {
        if (active) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.loadMembers(room); awaitCancellation() }
    }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    val directory = state.members?.takeIf { it.room == room }
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val keys = if(session.demo) persistentListOf() else visibleProfileKeys(list,(directory?.items ?: persistentListOf()).map { it.user }.toPersistentList(),ProfileContext.Room(room))
    val profiles = rememberProfilePresentation(keys,state.snapshot.presentationGeneration,active && !session.demo && room !in state.snapshot.revokedRooms,session.user,openProfiles,avatars=true)
    val pending = state.snapshot.membershipOperations.filter { it.intent.room == room && it.status != MembershipStatus.DraftCancelled }
    LazyColumn(Modifier.fillMaxSize().imePadding().testTag("member-list"), state = list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Row {
            TextButton(onClick = { act { model.loadMembers(room) } }, enabled = !busy && directory?.loading != true) { Text("刷新成员") }
            directory?.actorRole?.let { Text("你的角色：${it.title}", Modifier.padding(12.dp)) }
        } }
        if (directory == null || directory.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (directory?.stale == true && !directory.loading) item { Text("目录需要刷新后才能进行成员操作。") }
        directory?.administrationFeedback?.let { item { Text(it) } }
        directory?.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        if (directory?.allows(GroupPermission.Invite) == true) {
            item { OutlinedTextField(handle, { handle = it }, label = { Text("新成员的公开标识") }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth()) }
            item { Button(onClick = { act { model.prepareMember(room, null, MembershipAction.Add, handle = handle) } }, enabled = !busy && handle.isNotBlank()) { Text("添加成员") } }
        }
        item { Row { TextButton(onClick = openPolicies) { Text("群权限") }; TextButton(onClick = openAnnouncement) { Text("群公告") } } }
        if (directory?.earlier == true) item { Text("仅展示最近加载的 1000 名成员；刷新可从头查看。", style = MaterialTheme.typography.bodySmall) }
        items(directory?.items ?: persistentListOf(), key = { it.user.value }) { member ->
            val name = if (member.user == session.user) "我" else if(session.demo) state.snapshot.contacts.firstOrNull { it.id == member.user }?.name ?: "用户 ${member.user.value.takeLast(8)}" else profiles.name(member.user,ProfileContext.Room(room))
            ListItem(modifier=Modifier.testTag("member-profile/${member.user.value}").clickable(enabled=active,onClickLabel="查看成员资料") {openProfile(member.user)},
                headlineContent = { Text(name) }, supportingContent = { Text(member.role.title) },
                leadingContent = { Avatar(name,44,if(session.demo) null else profiles.avatars[ProfileKey(member.user,ProfileContext.Room(room))]) }, trailingContent = {
                if (member.user != session.user && member.role != MemberRole.Owner && directory?.allows(GroupPermission.Remove) == true)
                    TextButton(onClick = { act { model.prepareMember(room, member.user, MembershipAction.Remove) } }, enabled = !busy, modifier = Modifier.testTag("remove/${member.user.value}")) { Text("移除成员") }
            })
            if(member.user != session.user && member.role != MemberRole.Owner) Row {
                if(directory?.allows(GroupPermission.ChangeRoles) == true) TextButton(onClick = { act { model.prepareCapability(room,
                    GroupAction.Role(member.user, if(member.role == MemberRole.Admin) MemberRole.Member else MemberRole.Admin, requireNotNull(directory.revision))) } }, enabled = !busy, modifier = Modifier.testTag("role/${member.user.value}")) {
                    Text(if(member.role == MemberRole.Admin) "设为普通成员" else "设为管理员")
                }
                if(directory?.actorRole == MemberRole.Owner && !directory.stale && !directory.loading) TextButton(onClick = { act { model.prepareCapability(room,
                    GroupAction.Transfer(member.user, requireNotNull(directory.revision))) } }, enabled = !busy, modifier = Modifier.testTag("transfer/${member.user.value}")) { Text("转让群主") }
            }
            if(member.user != session.user && member.role != MemberRole.Owner) Row {
                val pendingAdmin = state.snapshot.administrationOperations.any { !it.terminal && it.intent.room == room && it.intent.target == member.user }
                if(directory?.allows(GroupPermission.Mute) == true) TextButton(onClick = { act { model.prepareAdministration(room,member.user,true) } },enabled = !busy && !pendingAdmin,modifier = Modifier.testTag("mute/${member.user.value}")) { Text("禁言 1 小时") }
                if(directory?.allows(GroupPermission.Remove) == true) TextButton(onClick = { act { model.prepareAdministration(room,member.user,false) } },enabled = !busy && !pendingAdmin,modifier = Modifier.testTag("moderate-remove/${member.user.value}")) { Text("管理移除") }
            }
        }
        if (directory?.nextCursor != null) item { TextButton(onClick = { act { model.loadMembers(room, more = true) } }, enabled = !busy && !directory.loading && !directory.stale) { Text("加载更多成员") } }
        if (directory?.actorRole != null && directory.actorRole != MemberRole.Owner) item {
            OutlinedButton(onClick = { act { model.prepareMember(room, session.user, MembershipAction.Remove) } }, enabled = !busy && !directory.stale && !directory.loading) { Text("退出群聊") }
        }
        if(directory?.actorRole == MemberRole.Owner) item {
            OutlinedButton(onClick = { act { model.prepareCapability(room, GroupAction.Dissolve(requireNotNull(directory.revision))) } }, enabled = !busy && !directory.stale && !directory.loading) { Text("解散群聊") }
        }
        items(state.snapshot.capabilityOperations.filter { it.intent.room == room && it.status != GroupCapabilityStatus.DraftCancelled }, key = { "capability/${it.intent.operation}" }) { work ->
            CapabilityWorkCard(work, directory?.stale == false && !directory.loading, busy, { act { model.reconfirmCapability(work) } },
                { act { model.discardCapability(work.intent.operation) } }, { act { model.retryCapability(work.intent.operation) } })
        }
        items(state.snapshot.administrationOperations.filter { it.intent.room == room && it.status != AdministrationStatus.DraftCancelled }, key = { "administration/${it.intent.key}" }) { work ->
            AdministrationWorkCard(work,!busy && directory?.stale == false && !directory.loading,
                { act { model.prepareAdministration(room,work.intent.target,work.intent.action is AdministrationAction.Mute,work) } },
                { act { model.discardAdministration(work.intent.key) } }, { act { model.retryAdministration(work.intent.key) } })
        }
        items(state.snapshot.moderationFacts.filter { it.room == room }.sortedByDescending { it.sequence },key = { "mute/${it.source}" }) { fact ->
            Text("禁言记录 · ${fact.target.value.takeLast(8)} · 截至 ${java.text.DateFormat.getDateTimeInstance().format(java.util.Date(fact.until))}",style = MaterialTheme.typography.bodySmall)
        }
        if (pending.isNotEmpty()) item { Text("成员操作记录", style = MaterialTheme.typography.titleMedium) }
        items(pending, key = { "operation/${it.intent.operation}" }) { work ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${if (work.intent.action == MembershipAction.Add) "添加" else "移除"} · ${work.intent.target.value.takeLast(8)}")
                    Text(when(work.status) {
                        MembershipStatus.DraftReady -> "已保存，正在确认操作权限"
                        MembershipStatus.DraftPaused -> "尚未提交，请刷新目录后重新确认，或取消草稿"
                        MembershipStatus.Pending -> "原命令等待确认，将自动继续"
                        MembershipStatus.NeedsAttention -> "结果尚未确认，请继续核对原命令"
                        MembershipStatus.Committed -> "操作成功，成员状态由同步更新"
                        MembershipStatus.Conflicted -> "成员版本已变化，请刷新后重新操作"
                        MembershipStatus.Rejected -> "此次操作未被允许：${membershipReason(work.reason)}"
                        MembershipStatus.Closed -> "原请求已关闭，可重新操作"
                        MembershipStatus.DraftCancelled -> "已取消"
                    })
                    Row {
                        if (work.status == MembershipStatus.DraftPaused) TextButton(onClick = {
                            act { model.prepareMember(room, work.intent.target, work.intent.action, draft = work.intent.operation) }
                        }, enabled = !busy && directory?.stale == false && !directory.loading) { Text("重新确认") }
                        if (work.admission == null && !work.terminal) TextButton(onClick = { act { model.discardMember(work.intent.operation) } }, enabled = !busy) { Text("取消草稿") }
                        if (work.status == MembershipStatus.NeedsAttention) TextButton(onClick = { act { model.retryMember(work.intent.operation) } }, enabled = !busy) { Text("继续核对") }
                    }
                }
            }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
private fun membershipReason(reason: String?) = when(reason) {
    "admissionExpired" -> "确认凭据已过期"; "permissionDenied" -> "当前权限不允许"; "roomNotFound" -> "群聊已不可用"
    "targetUnavailable" -> "目标用户已不可用"; "targetAlreadyMember" -> "对方已是成员"; "targetNotMember" -> "对方已不在群里"
    "memberLimitReached" -> "群成员已达上限"; else -> "请刷新成员后重试"
}
