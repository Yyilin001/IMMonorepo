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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.xmtx.im.sharedsdk.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList

@Composable internal fun SharedContactsContent(state: SharedAppState, model: SharedAppViewModel, groups: () -> Unit, chat: (String) -> Unit, profile: (String) -> Unit, join: () -> Unit) {
    val directory = state.snapshot?.directory ?: return
    val now = sharedDisplayTime()
    var query by rememberSaveable { mutableStateOf("") }
    var confirmation by remember { mutableStateOf<Pair<String, SharedSocialAction>?>(null) }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_contacts"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { TextButton(join, enabled = !state.busy, modifier = Modifier.testTag("shared_join_entry")) { Text("使用群邀请") } }
        item { Button(groups, enabled = !state.busy, modifier = Modifier.testTag("shared_groups")) { Text("群组") } }
        item {
            OutlinedTextField(query, { query = it }, label = { Text("公开账号") }, singleLine = true, modifier = Modifier.testTag("shared_lookup_handle"))
            Button({ model.lookupIdentity(query) }, enabled = !state.busy && query.isNotBlank(), modifier = Modifier.testTag("shared_lookup")) { Text("查找用户") }
        }
        directory.identity?.let { identity -> item {
            Text("${identity.name} · ${identity.handle}", modifier = Modifier.testTag("shared_identity"))
            Text(identity.userID)
            Row {
                TextButton({ confirmation = identity.userID to SharedSocialAction.Request }, enabled = !state.busy, modifier = Modifier.testTag("shared_request")) { Text("添加好友") }
                TextButton({ model.openDirect(identity.userID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_direct")) { Text("发起私聊") }
                TextButton({ confirmation = identity.userID to SharedSocialAction.Block }, enabled = !state.busy) { Text("屏蔽") }
            }
        } }
        item {
            Row { listOf(SharedContactScope.Accepted to "好友", SharedContactScope.Incoming to "收到", SharedContactScope.Outgoing to "发出", SharedContactScope.Blocked to "屏蔽").forEach { (scope, title) ->
                FilterChip(selected = directory.scope == scope, onClick = { model.contacts(scope) }, enabled = !state.busy,
                    label = { Text(title) }, modifier = Modifier.testTag("shared_contacts_${scope.wire}"))
            } }
        }
        if (directory.contacts.isEmpty()) item { Text("暂无记录") }
        items(directory.contacts, key = { it.userID }) { contact ->
            Column(Modifier.testTag("shared_contact_${contact.userID}")) {
                val presentation = directory.profiles.firstOrNull { it.userID == contact.userID && it.expiresAtElapsed > now }
                Text(presentation?.alias ?: presentation?.name ?: "用户 ${contact.userID}")
                TextButton({ profile(contact.userID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_profile_${contact.userID}")) { Text("资料与备注") }
                Row {
                    when (directory.scope) {
                        SharedContactScope.Accepted -> TextButton({ confirmation = contact.userID to SharedSocialAction.Remove }, enabled = !state.busy) { Text("删除好友") }
                        SharedContactScope.Incoming -> {
                            TextButton({ confirmation = contact.userID to SharedSocialAction.Accept }, enabled = !state.busy, modifier = Modifier.testTag("shared_accept_${contact.userID}")) { Text("接受") }
                            TextButton({ confirmation = contact.userID to SharedSocialAction.Reject }, enabled = !state.busy, modifier = Modifier.testTag("shared_reject_${contact.userID}")) { Text("拒绝") }
                        }
                        SharedContactScope.Outgoing -> Text("等待对方处理")
                        SharedContactScope.Blocked -> TextButton({ confirmation = contact.userID to SharedSocialAction.Unblock }, enabled = !state.busy) { Text("解除屏蔽") }
                    }
                    if (directory.scope != SharedContactScope.Blocked) TextButton({ confirmation = contact.userID to SharedSocialAction.Block }, enabled = !state.busy) { Text("屏蔽") }
                }
            }
        }
        item { Row {
            if (!directory.firstContacts) TextButton({ model.contacts(directory.scope) }, enabled = !state.busy) { Text("第一页") }
            if (directory.hasMoreContacts) TextButton(model::nextContacts, enabled = !state.busy) { Text("下一页") }
        } }
        items(directory.works.filter { it.kind in listOf("relationship", "userBlock", "directRoom") }, key = { "work_${it.id}" }) { work ->
            SharedWorkContent(work, state.busy, model, chat)
        }
    }
    confirmation?.let { (id, action) ->
        SharedConfirmation("确认${socialLabel(action)}？", "用户 $id", { confirmation = null }) {
            confirmation = null; model.socialAction(id, action)
        }
    }
}

@Composable internal fun SharedGroupsContent(state: SharedAppState, model: SharedAppViewModel, back: () -> Unit, open: (String) -> Unit) {
    val directory = state.snapshot?.directory ?: return
    var title by rememberSaveable { mutableStateOf("") }
    var selected by remember { mutableStateOf(persistentListOf<String>()) }
    var creating by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_group_directory"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { TextButton(back) { Text("返回") }; Text("群组", style = MaterialTheme.typography.headlineSmall) }
        item { Button({ creating = !creating; if (creating) model.contacts(SharedContactScope.Accepted) }, enabled = !state.busy, modifier = Modifier.testTag("shared_new_group")) { Text("创建群组") } }
        if (creating) {
            item { OutlinedTextField(title, { title = it }, label = { Text("群名称") }, modifier = Modifier.testTag("shared_group_title")); Text("选择好友（${selected.size}）") }
            items(directory.contacts, key = { "select_${it.userID}" }) { contact ->
                Row { Checkbox(checked = contact.userID in selected, onCheckedChange = { checked -> selected = if (checked) selected.add(contact.userID) else selected.remove(contact.userID) }, modifier = Modifier.testTag("shared_select_${contact.userID}").semantics { contentDescription = "选择成员 ${contact.userID}" }); Text(contact.userID) }
            }
            item {
                if (directory.hasMoreContacts) TextButton(model::nextContacts, enabled = !state.busy) { Text("更多好友") }
                Button({ confirm = true }, enabled = !state.busy && title.isNotBlank(), modifier = Modifier.testTag("shared_create_group")) { Text("确认建群") }
            }
        }
        items(directory.groups, key = { it.id }) { row ->
            ListItem(headlineContent = { Text(row.title) }, modifier = Modifier.testTag("shared_group_${row.id}").clickable(enabled = !state.busy) { open(row.id) })
        }
        item { Row {
            if (!directory.firstGroups) TextButton(model::firstGroups, enabled = !state.busy) { Text("第一页") }
            if (directory.hasMoreGroups) TextButton(model::nextGroups, enabled = !state.busy) { Text("下一页") }
        } }
        items(directory.works.filter { it.kind == "groupRoom" }, key = { it.id }) { SharedWorkContent(it, state.busy, model, open) }
    }
    if (confirm) SharedConfirmation("创建群组？", "$title · ${selected.size} 位受邀成员", { confirm = false }) {
        confirm = false; creating = false; model.createGroup(title, selected); title = ""; selected = persistentListOf()
    }
}

private data class GroupConfirmation(val label: String, val action: SharedGroupAction, val revision: Long,
    val target: String? = null, val text: String? = null, val role: SharedRole? = null,
    val permissions: kotlinx.collections.immutable.PersistentList<SharedPermission>? = null)

@Composable internal fun SharedGroupContent(state: SharedAppState, roomID: String, model: SharedAppViewModel, back: () -> Unit, chat: () -> Unit, invitations: () -> Unit, avatar: () -> Unit) {
    val group = state.snapshot?.directory?.group?.takeIf { it.roomID == roomID }
    var muteTarget by remember(roomID) { mutableStateOf<Pair<SharedMember, Long>?>(null) }
    var confirmation by remember(roomID) { mutableStateOf<GroupConfirmation?>(null) }
    var target by rememberSaveable(roomID) { mutableStateOf("") }
    var announcement by rememberSaveable(roomID, group?.announcementRevision) { mutableStateOf(group?.announcement ?: "") }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_group_detail"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Row { TextButton(back) { Text("返回") }; TextButton({ model.openGroup(roomID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_group_refresh")) { Text("刷新成员") }; TextButton(chat, enabled = !state.busy) { Text("聊天") } } }
        if (group == null) item { Text("正在读取群组，或已失去访问权限") }
        else {
            item { Text("我的角色：${roleLabel(group.actorRole)} · 成员修订 ${group.revision}", modifier = Modifier.testTag("shared_group_role")); Text(group.announcement.ifEmpty { "暂无公告" }, modifier = Modifier.testTag("shared_announcement")) }
            item { Button(avatar, enabled = !state.busy, modifier = Modifier.testTag("shared_group_avatar")) { Text("群头像") } }
            if (SharedPermission.InviteMembers in group.permissions) item { Button(invitations, enabled = !state.busy, modifier = Modifier.testTag("shared_invitation_management")) { Text("群邀请与审批") } }
            if (SharedPermission.ManageAnnouncements in group.permissions) item {
                OutlinedTextField(announcement, { announcement = it }, label = { Text("群公告") }, modifier = Modifier.testTag("shared_announcement_input"))
                Button({ confirmation = GroupConfirmation("更新公告", SharedGroupAction.Announcement, group.announcementRevision, text = announcement) }, enabled = !state.busy, modifier = Modifier.testTag("shared_save_announcement")) { Text("更新公告") }
            }
            if (SharedPermission.InviteMembers in group.permissions) item {
                OutlinedTextField(target, { target = it }, label = { Text("成员用户 ID") }, modifier = Modifier.testTag("shared_member_id"))
                Button({ confirmation = GroupConfirmation("添加成员", SharedGroupAction.Add, group.revision, target = target) }, enabled = !state.busy && target.isNotBlank(), modifier = Modifier.testTag("shared_add_member")) { Text("添加成员") }
            }
            items(group.members, key = { it.userID }) { member ->
                Column(Modifier.testTag("shared_member_${member.userID}")) {
                    Text("${member.userID} · ${roleLabel(member.role)}")
                    if (member.userID != state.snapshot?.userID && member.role != SharedRole.Owner) {
                        FlowRow {
                            if (SharedPermission.MuteMembers in group.permissions) TextButton({ muteTarget = member to group.revision }, enabled = !state.busy, modifier = Modifier.testTag("shared_mute_${member.userID}")) { Text("禁言一小时") }
                            if (SharedPermission.RemoveMembers in group.permissions) TextButton({ confirmation = GroupConfirmation("移除成员", SharedGroupAction.Remove, group.revision, member.userID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_remove_${member.userID}")) { Text("移除") }
                            if (SharedPermission.ChangeMemberRoles in group.permissions) TextButton({ confirmation = GroupConfirmation("修改角色", SharedGroupAction.Role, group.revision, member.userID, role = if (member.role == SharedRole.Member) SharedRole.Admin else SharedRole.Member) }, enabled = !state.busy, modifier = Modifier.testTag("shared_role_${member.userID}")) { Text(if (member.role == SharedRole.Member) "设为管理员" else "设为成员") }
                            if (group.actorRole == SharedRole.Owner) TextButton({ confirmation = GroupConfirmation("转让群主", SharedGroupAction.Transfer, group.revision, member.userID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_transfer_${member.userID}")) { Text("转让群主") }
                        }
                    }
                }
            }
            if (group.hasMore) item { TextButton({ model.nextGroupMembers(roomID) }, enabled = !state.busy) { Text("下一页成员") } }
            if (group.actorRole == SharedRole.Owner && group.policiesReady) {
                items(group.policies, key = { "policy_${it.role}" }) { policy ->
                    var selected by remember(policy) { mutableStateOf(policy.permissions) }
                    Text("${roleLabel(policy.role)}权限")
                    SharedPermission.entries.forEach { permission -> Row {
                        Checkbox(permission in selected, { checked -> selected = if (checked) selected.add(permission) else selected.remove(permission) }, modifier = Modifier.testTag("shared_permission_${policy.role.wire}_${permission.wire}").semantics { contentDescription = "${roleLabel(policy.role)}${permission.label}" })
                        Text(permission.label)
                    } }
                    Button({ confirmation = GroupConfirmation("修改角色权限", SharedGroupAction.Permissions, policy.revision, role = policy.role, permissions = selected.toPersistentList()) }, enabled = !state.busy, modifier = Modifier.testTag("shared_save_permissions_${policy.role.wire}")) { Text("保存权限") }
                }
            }
            item {
                if (group.actorRole == SharedRole.Owner) Button({ confirmation = GroupConfirmation("解散群组", SharedGroupAction.Dissolve, group.revision) }, enabled = !state.busy, modifier = Modifier.testTag("shared_dissolve")) { Text("解散群组") }
                else Button({ confirmation = GroupConfirmation("退出群组", SharedGroupAction.Leave, group.revision) }, enabled = !state.busy, modifier = Modifier.testTag("shared_leave_group")) { Text("退出群组") }
            }
        }
        items(state.snapshot?.directory?.works?.filter { it.kind !in listOf("relationship", "userBlock", "directRoom", "groupRoom") } ?: emptyList(), key = { it.id }) { SharedWorkContent(it, state.busy, model) {} }
    }
    muteTarget?.let { (member, revision) -> SharedConfirmation("禁言一小时？", member.userID, { muteTarget = null }) {
        muteTarget = null; model.muteMember(roomID, member.userID, revision)
    } }
    confirmation?.let { value -> SharedConfirmation("确认${value.label}？", listOfNotNull(value.target, value.text, value.role?.let(::roleLabel)).joinToString("\n"), { confirmation = null }) {
        confirmation = null; model.groupAction(roomID, value.action, value.revision, value.target, value.text, value.role, value.permissions)
    } }
}

@Composable internal fun SharedWorkContent(work: SharedWork, busy: Boolean, model: SharedAppViewModel, open: (String) -> Unit) {
    Column(Modifier.testTag("shared_work_${work.id}")) {
        Text("${work.target} · ${workLabel(work.status)}")
        if (work.status == "paused") TextButton({ model.discardDirectoryDraft(work.id) }, enabled = !busy, modifier = Modifier.testTag("shared_discard_${work.id}")) { Text("放弃草稿，刷新后重新操作") }
        if (work.retryable) TextButton({ model.retryDirectoryWork(work.id) }, enabled = !busy) { Text("重试确认结果") }
        work.roomID?.let { room -> TextButton({ open(room) }, enabled = !busy, modifier = Modifier.testTag("shared_open_result_${work.kind}")) { Text("进入会话") } }
    }
}
@Composable internal fun SharedConfirmation(title: String, detail: String, dismiss: () -> Unit, confirm: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text(title) }, text = { Text(detail) },
        confirmButton = { TextButton(confirm, modifier = Modifier.testTag("shared_confirm")) { Text("确认") } }, dismissButton = { TextButton(dismiss) { Text("取消") } })
}
private fun roleLabel(role: SharedRole) = when (role) { SharedRole.Owner -> "群主"; SharedRole.Admin -> "管理员"; SharedRole.Member -> "成员" }
private fun socialLabel(action: SharedSocialAction) = when (action) {
    SharedSocialAction.Request -> "添加好友"; SharedSocialAction.Accept -> "接受请求"; SharedSocialAction.Reject -> "拒绝请求"
    SharedSocialAction.Remove -> "删除好友"; SharedSocialAction.Block -> "屏蔽用户"; SharedSocialAction.Unblock -> "解除屏蔽"
}
private fun workLabel(status: String) = when (status) {
    "committed" -> "操作成功"; "rejected", "conflicted" -> "操作未获通过，请刷新后重新确认"
    "closed", "cancelled", "cancelledLocally" -> "操作已关闭"; "paused", "expiredUnsubmitted", "needsConfirmation" -> "确认已过期，请重新操作"
    "needsAttention" -> "需要确认结果"; "waitingForAuthentication" -> "等待认证"; "waitingForNetwork" -> "等待网络"
    else -> "正在处理"
}
