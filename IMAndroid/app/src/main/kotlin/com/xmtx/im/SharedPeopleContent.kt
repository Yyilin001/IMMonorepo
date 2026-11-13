package com.xmtx.im

import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.sharedsdk.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** UI expiry uses the conservative monotonic deadline supplied by Swift; no access policy here. */
@Composable internal fun sharedDisplayTime(): Long {
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    LaunchedEffect(Unit) { while (true) { now = SystemClock.elapsedRealtime(); delay(200) } }
    return now
}
@Composable internal fun SharedProfileContent(state: SharedAppState, userID: String, model: SharedAppViewModel, back: () -> Unit) {
    LaunchedEffect(userID) { model.openProfile(userID) }
    DisposableEffect(userID) { onDispose { model.clearDiscovery() } }
    val now = sharedDisplayTime()
    val profile = state.snapshot?.directory?.profiles?.firstOrNull { it.userID == userID && it.expiresAtElapsed > now }
    var alias by remember(profile?.aliasRevision) { mutableStateOf(profile?.alias ?: "") }
    var confirm by remember { mutableStateOf(false) }
    val bitmap by produceState<ImageBitmap?>(null, profile?.avatar, profile?.expiresAtElapsed) {
        value = null
        val encoded = profile?.avatar
        if (encoded != null) value = withContext(Dispatchers.Default) {
            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth !in 1..4096 || bounds.outHeight !in 1..4096) null
            else BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = maxOf(1, maxOf(bounds.outWidth, bounds.outHeight) / 256) })?.asImageBitmap()
        }
    }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_profile_detail"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item { Row { TextButton(back) { Text("返回") }; TextButton({ model.openProfile(userID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_profile_refresh")) { Text("刷新资料") } } }
        if (profile == null) item { Text(if (state.busy) "正在读取资料" else "资料暂不可用或展示授权已到期") }
        else {
            item {
                Text(profile.name, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.testTag("shared_profile_name"))
                Text(profile.handle); Text(userID)
                if (bitmap != null && profile.expiresAtElapsed > now) Image(bitmap!!, contentDescription = "联系人头像", modifier = Modifier.size(96.dp).testTag("shared_profile_avatar"))
                else Text("暂无可用头像")
            }
            item {
                OutlinedTextField(alias, { alias = it }, label = { Text("我的备注（留空删除）") }, modifier = Modifier.testTag("shared_alias"))
                Button({ confirm = true }, enabled = !state.busy, modifier = Modifier.testTag("shared_save_alias")) { Text("保存备注") }
            }
        }
        items(state.snapshot?.directory?.works?.filter { it.kind == "contactAlias" } ?: emptyList(), key = { it.id }) { SharedWorkContent(it, state.busy, model) {} }
    }
    if (confirm) {
        // Capture the exact displayed revision in the confirmation instance.
        val observed = remember { profile }
        SharedConfirmation("保存备注？", alias, { confirm = false }) {
            confirm = false; if (observed != null) model.saveAlias(userID, alias, observed.aliasRevision)
        }
    }
}

@Composable internal fun SharedInvitationsContent(state: SharedAppState, roomID: String, model: SharedAppViewModel, back: () -> Unit) {
    LaunchedEffect(roomID) { model.invitations(roomID) }
    DisposableEffect(roomID) { onDispose { model.clearDiscovery() } }
    val context = LocalContext.current
    val community = state.snapshot?.directory?.community?.takeIf { it.roomID == roomID }
    val group = state.snapshot?.directory?.group?.takeIf { it.roomID == roomID }
    var confirmation by remember { mutableStateOf<Triple<SharedInviteAction, String?, Long>?>(null) }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_invitations"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Row { TextButton(back) { Text("返回") }; TextButton({ model.invitations(roomID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_invites_refresh")) { Text("刷新邀请") } } }
        item { Text("邀请一小时内有效，最多批准 10 人")
            Button({ group?.let { confirmation = Triple(SharedInviteAction.Create, null, it.revision) } }, enabled = !state.busy && group != null, modifier = Modifier.testTag("shared_invite_create")) { Text("创建邀请") }
        }
        items(community?.invites ?: emptyList(), key = { it.id }) { invite ->
            Text("已使用 ${invite.used}/${invite.maximum} · 到期 ${java.util.Date(invite.expires)}")
            Row {
                TextButton({ context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(android.content.Intent.EXTRA_TEXT, invite.url) }, "分享群邀请")) }, enabled = !state.busy) { Text("分享邀请") }
                TextButton({ group?.let { confirmation = Triple(SharedInviteAction.Revoke, invite.id, it.revision) } }, enabled = !state.busy, modifier = Modifier.testTag("shared_invite_revoke_${invite.id}")) { Text("撤销") }
            }
        }
        item { Text("入群申请", style = MaterialTheme.typography.titleLarge) }
        items(community?.requests ?: emptyList(), key = { it.id }) { request ->
            Text(request.userID); Text(request.note); Text(joinStateLabel(request.state))
            Row {
                TextButton({ group?.let { confirmation = Triple(SharedInviteAction.Approve, request.id, it.revision) } }, enabled = !state.busy, modifier = Modifier.testTag("shared_join_approve_${request.id}")) { Text("批准") }
                TextButton({ group?.let { confirmation = Triple(SharedInviteAction.Reject, request.id, it.revision) } }, enabled = !state.busy, modifier = Modifier.testTag("shared_join_reject_${request.id}")) { Text("拒绝") }
            }
        }
        if (community?.hasMore == true) item { TextButton({ model.nextInvitations(roomID) }, enabled = !state.busy) { Text("下一页申请") } }
        items(state.snapshot?.directory?.works?.filter { it.kind.startsWith("groupInvite") || it.kind.startsWith("groupJoin") } ?: emptyList(), key = { it.id }) { SharedWorkContent(it, state.busy, model) {} }
    }
    confirmation?.let { value -> SharedConfirmation("确认群邀请操作？", when (value.first) { SharedInviteAction.Create -> "创建一小时邀请"; SharedInviteAction.Revoke -> "撤销后此邀请不能继续使用"; SharedInviteAction.Approve -> "批准此用户入群"; else -> "拒绝此申请" }, { confirmation = null }) {
        confirmation = null; model.inviteAction(roomID, value.first, value.third, value.second)
    } }
}

@Composable internal fun SharedJoinContent(state: SharedAppState, model: SharedAppViewModel, back: () -> Unit) {
    // Bearers are deliberately not rememberSaveable and never enter a navigation route.
    var input by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { model.clearDiscovery() } }
    val preview = state.snapshot?.directory?.community?.preview
    LazyColumn(Modifier.fillMaxSize().testTag("shared_join"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { SharedInviteScanner(state, model) }
        item { TextButton(back) { Text("返回") } }
        item {
            OutlinedTextField(input, { input = it }, label = { Text("群邀请链接或邀请码") }, visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(), modifier = Modifier.testTag("shared_invite_input"))
            Button({ val once = input; input = ""; model.previewInvite(once) }, enabled = !state.busy, modifier = Modifier.testTag("shared_invite_preview")) { Text("查看邀请") }
        }
        preview?.let { value -> item {
            TextButton(model::refreshInvite, enabled = !state.busy, modifier = Modifier.testTag("shared_join_refresh")) { Text("刷新申请状态") }
            Text(value.title, modifier = Modifier.testTag("shared_invite_title")); Text(if (value.member) "已加入该群" else value.state?.let(::joinStateLabel) ?: "尚未申请")
            OutlinedTextField(note, { note = it }, label = { Text("申请说明") }, modifier = Modifier.testTag("shared_join_note"))
            Button({ confirm = true }, enabled = !state.busy && value.canSubmit, modifier = Modifier.testTag("shared_join_submit")) { Text("申请入群") }
            if (value.canCancel) TextButton({ model.inviteAction(value.roomID, SharedInviteAction.Cancel) }, enabled = !state.busy, modifier = Modifier.testTag("shared_join_cancel")) { Text("取消申请") }
        } }
        items(state.snapshot?.directory?.works?.filter { it.kind == "groupJoinRequest" } ?: emptyList(), key = { it.id }) { SharedWorkContent(it, state.busy, model) {} }
    }
    if (confirm) SharedConfirmation("申请加入该群？", preview?.title ?: "", { confirm = false }) { confirm = false; preview?.let { model.inviteAction(it.roomID, SharedInviteAction.Submit, note = note) } }
}

private fun joinStateLabel(state: String): String = when (state) {
    "pending" -> "等待审批"; "approving" -> "正在批准"; "approved" -> "已批准"
    "rejected" -> "已拒绝，请获取新的邀请"; "cancelled" -> "已取消，请获取新的邀请"; else -> "正在更新"
}
