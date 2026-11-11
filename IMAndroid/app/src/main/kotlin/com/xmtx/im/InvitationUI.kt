package com.xmtx.im

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.Alignment
import kotlinx.collections.immutable.toPersistentMap
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first

internal val InvitationAction.title: String get() = when(this) {
    is InvitationAction.Create -> "创建邀请"; is InvitationAction.Revoke -> "撤销邀请"
    is InvitationAction.Submit -> "申请加入"; is InvitationAction.Cancel -> "撤回申请"
    is InvitationAction.Decide -> if(approve) "同意入群" else "拒绝申请"
}
@Composable internal fun InvitationsPage(room: RoomId?, app: AppState, session: SessionUi.SignedIn, active: Boolean,
    open: (RoomId?) -> InvitationManagement?, openProfiles: () -> ProfilePresentationPage?, inbox: InvitationInbox? = null) {
    val demo = session.demo
    val permitted = active && !demo && (room == null || room !in app.snapshot.revokedRooms)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var scanner by remember { mutableStateOf(false) }
    var management by remember { mutableStateOf<InvitationManagement?>(null) }
    // Bearer input is never saveable and is erased whenever this page loses foreground ownership.
    var input by remember { mutableStateOf("") }; var note by remember { mutableStateOf("") }
    LaunchedEffect(room,permitted,session.user,lifecycle,inbox) {
        if(permitted) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val opened = open(room); management = opened
            try {
                coroutineScope {
                    launch { opened?.refresh() }
                    if (opened != null && inbox != null && room == null) launch {
                        inbox.ticket.filterNotNull().collectLatest { ticket ->
                            opened.state.first { !it.busy }
                            inbox.take(ticket)?.let { secret ->
                                input = invitationURL(secret)
                                note = ""
                                opened.preview(input)
                            }
                        }
                    }
                    while(isActive) { opened?.tick(); delay(1000) }
                }
            } finally { opened?.close(); if(management === opened) management = null; input = ""; note = ""; scanner = false }
        }
    }
    DisposableEffect(Unit) { onDispose { input = ""; note = ""; management?.close() } }
    val current = management
    val observed = current?.state?.collectAsState()?.value
    val state = if(permitted) observed ?: InvitationManagementState() else InvitationManagementState()
    val list = rememberLazyListState()
    val rows = remember(state.requests,room) {
        state.requests.filter { it.room == room && it.state == "pending" }
            .associate { "request/${it.request}" to it.presentationKey }.toPersistentMap()
    }
    val keys = visiblePresentationKeys(list,rows)
    val profiles = rememberProfilePresentation(keys,app.snapshot.presentationGeneration,
        permitted && room != null && !state.loading,session.user,openProfiles,avatars=true)
    val scope = rememberCoroutineScope(); val context = LocalContext.current
    val enabled = permitted && current != null && !state.busy && !state.loading
    fun act(block: suspend () -> Unit) { scope.launch { block() } }
    LazyColumn(Modifier.fillMaxSize().imePadding().testTag("invitation-page"), state = list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(demo) item { Text("离线演示 · 登录后可创建邀请、申请加入和审批") }
        if(room == null) {
            item { Text("粘贴邀请链接，查看群信息后申请加入。") }
            item { OutlinedButton(onClick={ scanner=true },enabled=enabled && !demo,modifier=Modifier.testTag("scan-invitation")) { Text("扫描二维码") } }
            item { OutlinedTextField(input, { input = it; current?.inputChanged() }, label = { Text("邀请链接或邀请码") }, modifier = Modifier.fillMaxWidth().testTag("invite-input"), enabled = !state.busy, singleLine = true) }
            item { Button(onClick = { act { current?.preview(input) } }, enabled = enabled && input.isNotBlank()) { Text("查看邀请") } }
            state.preview?.let { preview ->
                item { Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(preview.title, style = MaterialTheme.typography.titleLarge)
                    Text(when { preview.alreadyMember -> "你已在群内"; else -> when(preview.requestState) {
                        "pending" -> "申请等待审批"; "approving" -> "正在确认入群结果"; "approved" -> "申请已通过，群聊会在同步后显示"
                        "rejected" -> "申请已被拒绝"; "cancelled" -> "申请已撤回"; else -> "可以申请加入"
                    } })
                } } }
                if(!preview.alreadyMember && preview.requestState in setOf(null,"cancelled")) {
                    item { OutlinedTextField(note, { note = it }, label = { Text("申请说明（选填）") }, modifier = Modifier.fillMaxWidth(), enabled = enabled) }
                    item { Button(onClick = { current?.submit(note) }, enabled = enabled) { Text("申请加入") } }
                }
                if(preview.requestState == "pending") item { OutlinedButton(onClick = { current?.cancel() }, enabled = enabled) { Text("撤回申请") } }
                item { TextButton(onClick = { act { current?.refresh() } }, enabled = enabled) { Text("刷新申请状态") } }
            }
        } else {
            item { Text("邀请有效期 7 天，最多允许 100 人通过审批加入。") }
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { current?.create() }, enabled = enabled && state.revision != null) { Text("创建邀请") }
                TextButton(onClick = { act { current?.refresh() } }, enabled = enabled) { Text("刷新") }
            } }
            item { Text("有效邀请", style = MaterialTheme.typography.titleMedium) }
            if(state.links.isEmpty() && !state.loading) item { Text("暂无可分享的邀请") }
            items(state.links, key = { "link/${it.invite}" }) { link ->
                Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                    Text(link.title,style = MaterialTheme.typography.titleMedium)
                    Text("已通过 ${link.approvedUses} / ${link.maximumUses} 人",style = MaterialTheme.typography.bodyMedium)
                    Text("邀请 ${link.invite.takeLast(8)}",style = MaterialTheme.typography.bodySmall)
                    InvitationQrImage(link.secret,link.invite)
                    Row {
                        TextButton(onClick = {
                            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT,invitationURL(link.secret)) },"分享群邀请"))
                        }, enabled = enabled) { Text("分享邀请") }
                        TextButton(onClick = { current?.revoke(link.invite) },enabled = enabled) { Text("撤销邀请") }
                    }
                } }
            }
            item { Text("待审批申请",style = MaterialTheme.typography.titleMedium) }
            if(state.requests.isEmpty() && !state.loading) item { Text("暂无待审批申请") }
            items(state.requests,key = { "request/${it.request}" }) { request ->
                Card(Modifier.fillMaxWidth().testTag("invite-request/${request.request}")) { Column(Modifier.padding(16.dp)) {
                    val name = profiles.name(request.applicant,ProfileContext.GroupJoinReview(request.room))
                    Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                        Avatar(name,44,profiles.avatars[request.presentationKey])
                        Text(name,style=MaterialTheme.typography.bodyMedium,modifier=Modifier.testTag("invite-applicant/${request.request}"))
                    }
                    request.note?.let { Text(it) }
                    Row {
                        TextButton(onClick = { current?.decide(request.request,true) },enabled = enabled) { Text("同意入群") }
                        TextButton(onClick = { current?.decide(request.request,false) },enabled = enabled) { Text("拒绝申请") }
                    }
                } }
            }
            if(state.cursor != null) item { TextButton(onClick = { act { current?.more() } }, enabled = enabled) { Text("加载更多申请") } }
        }
        if(state.loading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        state.error?.let { item { Text(it,color = MaterialTheme.colorScheme.error) } }
        if(state.works.isNotEmpty()) item { Text("操作记录",style = MaterialTheme.typography.titleMedium) }
        items(state.works.reversed(),key = { "work/${it.intent.key}" }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp)) {
                Text(work.intent.action.title,style = MaterialTheme.typography.titleSmall)
                Text(when(work.status) {
                    InvitationStatus.DraftReady -> "正在核对权限"; InvitationStatus.DraftPaused -> "尚未提交，需要重新确认"
                    InvitationStatus.DraftCancelled -> "草稿已取消"; InvitationStatus.Pending -> "正在确认结果"
                    InvitationStatus.NeedsAttention -> "结果尚未确定，请继续核对"; InvitationStatus.Committed -> "操作成功"
                    InvitationStatus.Rejected -> "操作未被允许，请刷新状态"; InvitationStatus.Conflicted -> "群状态已变化，请重新确认"
                    InvitationStatus.Closed -> "原请求已关闭"
                })
                if(work.status == InvitationStatus.DraftPaused) TextButton(onClick = { current?.reconfirm(work) }, enabled = enabled) { Text("重新确认") }
                if(work.draft && !work.terminal) {
                    TextButton(onClick = { act { current?.discard(work.intent.key) } },enabled = enabled) { Text("取消草稿") }
                    TextButton(onClick = { act { current?.closeOriginal(work.intent.key) } },enabled = enabled) { Text("核对并关闭原请求") }
                }
                if(work.status == InvitationStatus.NeedsAttention) TextButton(onClick = { act { current?.retry(work.intent.key) } },enabled = enabled) { Text("继续核对原操作") }
            } }
        }
    }
    if(scanner && permitted && current!=null) InvitationScanner(onDismiss={scanner=false}) { secret ->
        scanner=false
        input=invitationURL(secret);note=""
        act { current.preview(input) }
    }
    state.prompt?.let { prompt ->
        val action = prompt.confirmation.intent.action
        AlertDialog(onDismissRequest = { current?.dismiss() },title = { Text("${action.title}？") },text = { Text(when(action) {
            is InvitationAction.Create -> "创建有效期 7 天、最多 100 人通过审批的群邀请。"
            is InvitationAction.Revoke -> "撤销后，此邀请不能再用于新的入群申请。"
            is InvitationAction.Submit -> "向「${state.preview?.title ?: "此群"}」提交入群申请。"
            is InvitationAction.Cancel -> "撤回当前入群申请。"
            is InvitationAction.Decide -> if(action.approve) "允许此申请人加入群聊。" else "拒绝此申请人的入群申请。"
        }) },confirmButton = { TextButton(onClick = { act { current?.confirm() } }) { Text("确认") } },
            dismissButton = { TextButton(onClick = { current?.dismiss() }) { Text("取消") } })
    }
}
