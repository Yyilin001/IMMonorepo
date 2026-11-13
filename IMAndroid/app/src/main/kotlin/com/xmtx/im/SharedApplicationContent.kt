package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.PeopleOutline
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.xmtx.im.sharedsdk.*
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import kotlinx.serialization.Serializable

@Serializable private sealed interface SharedRoute : NavKey {
    @Serializable data object Home : SharedRoute
    @Serializable data class Chat(val roomID: String) : SharedRoute
    @Serializable data class Profile(val userID: String) : SharedRoute
    @Serializable data class Invitations(val roomID: String) : SharedRoute
    @Serializable data class Resource(val roomID: String, val messageID: String, val mediaID: String) : SharedRoute
    @Serializable data class Search(val roomID: String?) : SharedRoute
    @Serializable data class Forward(val roomID: String, val messageID: String, val revision: Long) : SharedRoute
    @Serializable data class Readers(val roomID: String, val messageID: String) : SharedRoute
    @Serializable data object Transfers : SharedRoute
    @Serializable data class Avatar(val roomID: String?) : SharedRoute
    @Serializable data object Join : SharedRoute
    @Serializable data object Groups : SharedRoute
    @Serializable data class Group(val roomID: String) : SharedRoute
}

@Composable internal fun SharedApplicationContent(model: SharedAppViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle, model) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) model.foreground(true)
            if (event == Lifecycle.Event.ON_STOP) model.foreground(false)
        }
        lifecycle.lifecycle.addObserver(observer)
        model.foreground(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose { lifecycle.lifecycle.removeObserver(observer); model.foreground(false) }
    }
    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            if (state.snapshot?.userID == null) {
                var account by rememberSaveable { mutableStateOf("") }
                // Password is never saved into Activity recreation state.
                var password by remember { mutableStateOf("") }
                var url by remember(state.endpoint) { mutableStateOf(state.endpoint?.accountURL ?: "") }
                var port by remember(state.endpoint) { mutableStateOf((state.endpoint?.gatewayPort ?: 7443).toString()) }
                Column(Modifier.safeDrawingPadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("登录", style = MaterialTheme.typography.headlineLarge)
                    OutlinedTextField(url, { url = it }, label = { Text("服务器地址") }, singleLine = true, modifier = Modifier.testTag("shared_server"))
                    OutlinedTextField(port, { port = it }, label = { Text("连接端口") }, singleLine = true, modifier = Modifier.testTag("shared_port"))
                    OutlinedTextField(account, { account = it }, label = { Text("账号") }, singleLine = true, modifier = Modifier.testTag("shared_account"))
                    OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true,
                        visualTransformation = PasswordVisualTransformation(), modifier = Modifier.testTag("shared_password"))
                    if (state.exitPending) Button(onClick = model::signOut, enabled = !state.busy, modifier = Modifier.testTag("shared_retry_exit")) { Text("重试退出") }
                    Button(onClick = { val oneTime = password; password = ""; model.login(account, oneTime, url, port.toIntOrNull() ?: 0) },
                        enabled = !state.busy && !state.exitPending, modifier = Modifier.testTag("shared_login")) { Text(if (state.busy) "正在登录" else "登录") }
                    state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            } else {
                key(state.snapshot?.userID, state.generation) { SharedSignedIn(state, model) }

            }
        }
    }
}

@Composable private fun SharedSignedIn(state: SharedAppState, model: SharedAppViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val stack = rememberNavBackStack(SharedRoute.Home)
    val root = stack.lastOrNull() == SharedRoute.Home
    val labels = listOf("消息", "联系人", "我的")
    val icons = listOf(Icons.AutoMirrored.Outlined.Chat, Icons.Outlined.PeopleOutline, Icons.Outlined.PersonOutline)
    Scaffold(bottomBar = {
        if (root) NavigationBar { labels.forEachIndexed { index, label ->
            NavigationBarItem(selected = tab == index, onClick = { if (tab == 1 && index != 1) model.clearDiscovery(); tab = index; if (index == 1) model.contacts(SharedContactScope.Accepted) }, icon = { Icon(icons[index], contentDescription = null) }, label = { Text(label) })
        } }
    }) { padding ->
        Column(Modifier.padding(padding).safeDrawingPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(when (state.snapshot?.state) {
                SharedSessionState.Connected -> "已连接"
                SharedSessionState.Connecting -> "连接中"
                else -> "离线 · 自动重连"
            }, modifier = Modifier.testTag("shared_connection"))
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            NavDisplay(backStack = stack, onBack = { if (stack.size > 1) stack.removeLastOrNull() },
                modifier = Modifier.weight(1f), entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
                entryProvider = entryProvider {
                    entry<SharedRoute.Home> {
                        Column {
                            Text(labels[tab], style = MaterialTheme.typography.headlineLarge)
                            when (tab) {
                                0 -> {
                                    TextButton({ stack.add(SharedRoute.Search(null)) }, modifier = Modifier.testTag("shared_search_all")) { Text("搜索消息") }
                                    val snapshot = state.snapshot!!
                                    if (snapshot.conversations.isEmpty()) Text("暂无会话")
                                    LazyColumn(Modifier.weight(1f).testTag("shared_conversations")) {
                                        items(snapshot.conversations, key = { it.id }) { row ->
                                            ListItem(headlineContent = { Text(row.title) }, supportingContent = { Text(row.preview) },
                                                modifier = Modifier.testTag("shared_room_${row.id}").clickable(enabled = !state.busy) {
                                                    model.openConversation(row.id); stack.add(SharedRoute.Chat(row.id))
                                                })
                                        }
                                    }
                                    Row {
                                        if (!snapshot.isFirstConversationPage) TextButton(model::firstConversations, enabled = !state.busy) { Text("返回最新会话") }
                                        if (snapshot.hasMoreConversations) TextButton(model::nextConversations, enabled = !state.busy) { Text("下一页会话") }
                                    }
                                }
                                1 -> SharedContactsContent(state, model, profile = { id -> stack.add(SharedRoute.Profile(id)) }, join = { stack.add(SharedRoute.Join) }, groups = { model.clearDiscovery(); stack.add(SharedRoute.Groups) }, chat = { room -> model.clearDiscovery(); model.openConversation(room); stack.add(SharedRoute.Chat(room)) })
                                2 -> {
                                    Button({ stack.add(SharedRoute.Avatar(null)) }, enabled = !state.busy, modifier = Modifier.testTag("shared_own_avatar")) { Text("编辑头像") }
                                    TextButton({ stack.add(SharedRoute.Transfers) }, modifier = Modifier.testTag("shared_all_transfers")) { Text("上传与下载任务") }
                                    Text(when (state.snapshot?.allowsStrangerMessages) { true -> "陌生人消息：允许"; false -> "陌生人消息：拒绝"; null -> "账户已登录" }, modifier = Modifier.testTag("shared_preference"))
                                    Button(model::signOut, enabled = !state.busy, modifier = Modifier.testTag("shared_sign_out")) { Text("退出登录") }
                                    TextButton(model::signOut, enabled = !state.busy, modifier = Modifier.testTag("shared_switch_account")) { Text("切换账号") }
                                }
                            }
                        }
                    }
                    entry<SharedRoute.Resource> { route -> SharedResourceContent(state, route.roomID, route.messageID, route.mediaID, model, back = { stack.removeLastOrNull() }, transfers = { stack.add(SharedRoute.Transfers) }) }
                    entry<SharedRoute.Transfers> { SharedTransfersContent(state, model) { stack.removeLastOrNull() } }
                    entry<SharedRoute.Avatar> { route -> SharedAvatarContent(state, model, route.roomID) { stack.removeLastOrNull() } }
                    entry<SharedRoute.Profile> { route -> SharedProfileContent(state, route.userID, model) { stack.removeLastOrNull() } }
                    entry<SharedRoute.Invitations> { route -> SharedInvitationsContent(state, route.roomID, model) { stack.removeLastOrNull() } }
                    entry<SharedRoute.Join> { SharedJoinContent(state, model) { stack.removeLastOrNull() } }
                    entry<SharedRoute.Groups> {
                        SharedGroupsContent(state, model, back = { stack.removeLastOrNull() }, open = { room -> model.openGroup(room); stack.add(SharedRoute.Group(room)) })
                    }
                    entry<SharedRoute.Group> { route ->
                        SharedGroupContent(state, route.roomID, model, avatar = { stack.add(SharedRoute.Avatar(route.roomID)) }, invitations = { stack.add(SharedRoute.Invitations(route.roomID)) }, back = { stack.removeLastOrNull() }, chat = { model.openConversation(route.roomID); stack.add(SharedRoute.Chat(route.roomID)) })
                    }
                    entry<SharedRoute.Search> { route ->
                        SharedSearchContent(state, model, route.roomID, back = { stack.removeLastOrNull() }, open = { hit ->
                            model.openConversation(hit.roomID, hit.id)
                            val existing = stack.indexOfLast { it is SharedRoute.Chat && it.roomID == hit.roomID }
                            if (existing >= 0) { while (stack.lastIndex > existing) stack.removeLastOrNull() }
                            else stack.add(SharedRoute.Chat(hit.roomID))
                        })
                    }
                    entry<SharedRoute.Readers> { route -> SharedReadersContent(state, model, route.roomID, route.messageID, back = { stack.removeLastOrNull() }) }
                    entry<SharedRoute.Forward> { route -> SharedForwardContent(state, model, route.roomID, route.messageID, route.revision, back = { stack.removeLastOrNull() }) }
                    entry<SharedRoute.Chat> { route ->
                        SharedChatContent(state, route.roomID, model, forward = { stack.add(SharedRoute.Forward(route.roomID, it.id, it.revision)) }, search = { stack.add(SharedRoute.Search(route.roomID)) }, readers = { stack.add(SharedRoute.Readers(route.roomID, it)) }, openResource = { message, media -> stack.add(SharedRoute.Resource(route.roomID, message, media)) }, transfers = { stack.add(SharedRoute.Transfers) }, back = { stack.removeLastOrNull() })
                    }
                })
        }
    }
}

@Composable private fun SharedChatContent(state: SharedAppState, roomID: String, model: SharedAppViewModel, forward: (SharedMessage) -> Unit, search: () -> Unit, readers: (String) -> Unit, openResource: (String, String) -> Unit, transfers: () -> Unit, back: () -> Unit) {
    val chat = state.snapshot?.chat?.takeIf { it.roomID == roomID }
    val list = rememberLazyListState()
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    SharedVisibleMessages(state, roomID, list, model)
    LaunchedEffect(chat?.focusMessageID, chat?.messages?.map { it.id }) {
        chat?.focusMessageID?.let { id -> chat.messages.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { list.scrollToItem(it) } }
    }
    var text by rememberSaveable(roomID) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row {
            TextButton(back, modifier = Modifier.testTag("shared_chat_back")) { Text("返回") }
            TextButton(search, modifier = Modifier.testTag("shared_search_room")) { Text("搜索") }
            TextButton(transfers, modifier = Modifier.testTag("shared_chat_transfers")) { Text("任务") }
            Text(state.snapshot?.conversations?.firstOrNull { it.id == roomID }?.title ?: "聊天", style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        }
        if (chat == null) {
            Text("正在读取聊天")
            if (!state.busy) TextButton({ model.openConversation(roomID) }) { Text("重试") }
        }
        Row {
            if (chat?.hasOlder == true) TextButton(model::olderMessages, enabled = !state.busy) { Text("更早消息") }
            if (chat?.isLatest == false) TextButton(model::latestMessages, enabled = !state.busy) { Text("最新消息") }
        }
        LazyColumn(Modifier.weight(1f).testTag("shared_messages"), state = list) {
            items(chat?.messages ?: kotlinx.collections.immutable.persistentListOf(), key = { it.id }) { message ->
                ListItem(overlineContent = { Text(if (message.senderID == state.snapshot?.userID) "我" else "对方") },
                    headlineContent = { Text(if (message.withdrawn) "消息已撤回" else message.text) },
                    supportingContent = { Column {
                        message.attachments.forEach { attachment -> TextButton({ openResource(message.id, attachment.id) }, modifier = Modifier.testTag("shared_attachment_${attachment.id}")) { Text(attachment.name) } }
                        SharedMessageActions(state, roomID, message, model, readers = { readers(message.id) })
                        SharedMessageInteractions(state, roomID, message, model, forward = { forward(message) })
                    } },
                    modifier = Modifier.testTag("shared_message_${message.id}"))
            }
            item { SharedInteractionWorkContent(state, roomID, model) }
            items(state.snapshot?.messaging?.takeIf { it.roomID == roomID }?.mutations ?: kotlinx.collections.immutable.persistentListOf(), key = { "mutation_" + it.id }) { work ->
                Column(Modifier.testTag("shared_mutation_${work.id}")) {
                    Text(when (work.status) { "conflicted" -> "消息已变化，请重新编辑"; "rejected", "expiredUnsubmitted", "closed" -> "修改未生效，请刷新后确认"; "needsAttention" -> "需要确认修改结果"; else -> "修改已保存，正在确认" })
                    work.text?.let { Text("编辑内容：$it") }
                    if (work.retryable) TextButton({ model.retryMessageAction(roomID, work.id) }, enabled = !state.busy) { Text("继续确认") }
                }
            }
            item {
                if (state.snapshot?.messaging?.canRetryRead == true) TextButton({ model.retryReadReceipt(roomID) }, enabled = !state.busy) { Text("继续确认已读回执") }
            }
            items(chat?.pending ?: kotlinx.collections.immutable.persistentListOf(), key = { "pending_" + it.id }) { message ->
                Column(Modifier.testTag("shared_pending_${message.id}")) {
                    Text(message.text)
                    Text(when (message.status) {
                        SharedSendStatus.Preparing, SharedSendStatus.Pending -> "等待发送"
                        SharedSendStatus.WaitingForNetwork -> "等待连接"
                        SharedSendStatus.WaitingForAuthentication -> "等待认证"
                        SharedSendStatus.AcceptedAwaitingProjection -> "已发送，正在同步"
                        SharedSendStatus.ConfirmingOutcome -> "正在确认发送结果"
                        SharedSendStatus.NeedsAttention -> "需要重试确认"
                        SharedSendStatus.ExpiredUnsubmitted -> "未发送，已过期"
                        SharedSendStatus.Closed -> "发送已关闭"
                        SharedSendStatus.Rejected -> "发送被拒绝"
                    })
                    if (message.status == SharedSendStatus.Preparing) TextButton({ model.cancelAttachmentSend(message.id) }, enabled = !state.busy) { Text("取消准备中的发送") }
                    if (message.status == SharedSendStatus.NeedsAttention) TextButton({ model.retrySend(message.id) }, enabled = !state.busy) { Text("重试确认") }
                }
            }
        }
        Row {
            if (chat?.hasMorePending == true) TextButton(model::nextPending, enabled = !state.busy) { Text("更多发送记录") }
            if ((chat?.pendingPage ?: 0) > 0) TextButton(model::firstPending, enabled = !state.busy) { Text("返回待发送消息") }
        }
        SharedAttachmentComposer(state, roomID, model, text) { text = "" }
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(text, { text = it }, label = { Text("消息") }, maxLines = 3, modifier = Modifier.weight(1f).testTag("shared_composer"))
            Button(onClick = { val frozen = text; text = ""; focus.clearFocus(); model.send(roomID, frozen) },
                enabled = !state.busy && chat != null && text.isNotBlank(), modifier = Modifier.testTag("shared_send")) { Text("发送") }
        }
    }
}
