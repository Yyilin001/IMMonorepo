@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package com.xmtx.im

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.collections.immutable.toPersistentMap
import kotlinx.collections.immutable.persistentListOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.Serializable
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Serializable sealed interface Route : NavKey {
    @Serializable data object Home : Route
    @Serializable data class LocalDirect(val operation: String) : Route
    @Serializable data class Chat(val room: String, val focus: String? = null) : Route
    @Serializable data class ComposeContent(val room: String) : Route
    @Serializable data class DraftImage(val room: String,val asset: String) : Route
    @Serializable data class SendHistory(val room: String) : Route
    @Serializable data class SendTasks(val room: String) : Route
    @Serializable data class MessagePlayback(val room: String,val message: String,val media: String) : Route
    @Serializable data class MessageFile(val room: String,val message: String,val media: String) : Route
    @Serializable data class MessageImage(val room: String,val message: String,val media: String) : Route
    @Serializable data class Profile(val user: String,val room: String?=null) : Route
    @Serializable data class NameEditor(val target: NameTarget) : Route
    @Serializable data class AvatarEditor(val id: String) : Route
    @Serializable data class ConversationResources(val room: String,val id: String=java.util.UUID.randomUUID().toString()) : Route
    @Serializable data class ResourceOwners(val kind:String,val transfer:String):Route
    @Serializable data class ResourceProfileOwner(val kind:String,val transfer:String,val intent:String):Route
    @Serializable data class ResourceGroupOwner(val kind:String,val transfer:String,val room:String,val operation:String):Route
    @Serializable data class ResourceDetail(val room:String,val media:String) : Route
    @Serializable data class AvatarResources(val id: String,val groupRoom: String?=null) : Route
    @Serializable data class AvatarCrop(val id: String) : Route
    @Serializable data class GroupAvatar(val room: String,val id: String) : Route
    @Serializable data class GroupAvatarCrop(val room: String,val id: String) : Route
    @Serializable data class EditMessage(val room: String, val message: String) : Route
    @Serializable data class Forward(val room: String, val message: String? = null) : Route
    @Serializable data class Reactions(val room: String, val message: String? = null) : Route
    @Serializable data class Moderation(val room: String) : Route
    @Serializable data class Reads(val room: String) : Route
    @Serializable data class Readers(val room: String,val message: String) : Route
    @Serializable data class Mutations(val room: String) : Route
    @Serializable data class Settings(val room: String) : Route
    @Serializable data class Members(val room: String) : Route
    @Serializable data class Invitations(val room: String) : Route
    @Serializable data class Policies(val room: String) : Route
    @Serializable data class Announcement(val room: String) : Route
    @Serializable data class Pins(val room: String) : Route
    @Serializable data class Page(val page: PageKind) : Route
}
@Serializable enum class PageKind(val title: String) {
    Archived("隐藏的聊天"), Search("搜索消息"), NewChat("发起聊天"), Groups("群聊"), CreateGroup("新建群聊"), JoinGroup("通过邀请加入"), Requests("新的朋友"), AddFriend("添加朋友"),
    Account("账号安全"), Privacy("隐私设置"), Blacklist("黑名单"), Identity("公开身份"), Devices("登录设备"),
    Favorites("收藏"), Resources("资源中心"), Downloads("下载任务"), Transfers("传输任务"), UnavailableRetention("失效资源保留"), Storage("存储管理"), Connection("连接状态")
}
private enum class Tab(val title: String, val icon: ImageVector) {
    Messages("消息", Icons.AutoMirrored.Outlined.Chat), Contacts("联系人", Icons.Outlined.PeopleOutline), Account("我的", Icons.Outlined.PersonOutline)
}

@Composable fun IMApp(state: AppState, model: AppViewModel) {
    val recovery by model.credentialRecovery.collectAsState()
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            if (recovery != CredentialRecoveryUi.AwaitingRegistration || state.session == SessionUi.SignedOut)
                CredentialRecoveryBanner(recovery, model::retryCredentialRecovery)
            Box(Modifier.weight(1f)) {
        when (val session = state.session) {
            SessionUi.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            SessionUi.SignedOut, SessionUi.Authenticating -> SignIn(state, model)
            is SessionUi.CredentialsUnavailable -> CredentialUnavailableScreen(session.reason, model::retryCredentialAccess, model::signOut)
            is SessionUi.LocalUnavailable -> LocalStoreUnavailableScreen(session.reason, state.localRecovery, model::retryLocalSession, model::signOut,
                model::prepareLocalRecovery, model::confirmLocalRecovery, model::dismissLocalRecovery)
            is SessionUi.SignedIn -> AccountNavigationState(session) { SignedIn(state, session, model) }
        }
            }
        }
    }
}

@Composable private fun CredentialRecoveryBanner(state: CredentialRecoveryUi, retry: () -> Unit) {
    if (state == CredentialRecoveryUi.Empty) return
    Surface(color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.fillMaxWidth().statusBarsPadding().testTag("credential-recovery")) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(when (state) {
                CredentialRecoveryUi.AwaitingRegistration -> "有未完成的登录，可继续登录或清理"
                CredentialRecoveryUi.Pending -> "设备清理正在等待服务确认"
                CredentialRecoveryUi.Paused -> "设备清理已暂停，原记录已保留"
                CredentialRecoveryUi.Unavailable -> "设备清理记录暂时无法处理"
                CredentialRecoveryUi.Checking -> "正在检查设备清理记录"
                CredentialRecoveryUi.Empty -> ""
            }, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            if (state == CredentialRecoveryUi.Paused || state == CredentialRecoveryUi.Unavailable || state == CredentialRecoveryUi.AwaitingRegistration)
                TextButton(onClick = retry, modifier = Modifier.testTag("credential-recovery-retry")) { Text("重试清理") }
        }
    }
}

@Composable internal fun CredentialUnavailableScreen(reason: CredentialStoreFailure.Reason, retry: () -> Unit, signOut: () -> Unit) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp).testTag("credentials-unavailable"),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("暂时无法恢复登录", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))
        Text(when (reason) {
            CredentialStoreFailure.Reason.Unavailable -> "设备凭据暂时无法读取，请解锁设备后重试。现有登录记录和本机数据已保留。"
            CredentialStoreFailure.Reason.Malformed -> "本机登录记录无法验证。可重试读取，或清除失效登录记录后重新登录；本机消息会保留。"
            CredentialStoreFailure.Reason.PermanentlyInvalidated -> "本机登录记录的设备密钥已不可用。可清除失效登录记录后重新登录；本机消息会保留。"
        })
        Spacer(Modifier.height(24.dp))
        Button(onClick = retry, modifier = Modifier.testTag("credentials-retry")) { Text("重试读取凭据") }
        if (reason != CredentialStoreFailure.Reason.Unavailable)
            Text("无法读取原登录凭据，因此清除本机记录不能确认原服务器设备会话已撤销。", style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = signOut, modifier = Modifier.testTag("credentials-sign-out")) {
            Text(if (reason == CredentialStoreFailure.Reason.Unavailable) "退出登录" else "清除失效登录记录")
        }
    }
}

/** Scope the back stack, selected tab and entry state together, including restored bundles. */
@Composable internal fun AccountNavigationState(session: SessionUi.SignedIn, content: @Composable () -> Unit) {
    val scope = "${session.user.value}/${session.demo}/${session.databaseIdentity?.value.orEmpty()}"
    val holder = rememberSaveableStateHolder()
    var previous by rememberSaveable { mutableStateOf(scope) }
    SideEffect {
        if (previous != scope) { holder.removeState(previous); previous = scope }
    }
    holder.SaveableStateProvider(scope, content)
}

@Composable internal fun LocalStoreUnavailableScreen(reason: LocalStoreFailure.Reason, recovery: LocalRecoveryUi,
    retry: () -> Unit, signOut: () -> Unit, prepare: () -> Unit, confirm: () -> Unit, dismiss: () -> Unit) {
    val resumed = rememberReadForeground()
    val busy = recovery.phase != LocalRecoveryPhase.Idle
    LaunchedEffect(resumed) { if (!resumed) dismiss() }
    DisposableEffect(Unit) { onDispose { dismiss() } }
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp).testTag("local-store-unavailable"),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("暂时无法打开本机数据", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))
        Text(when (reason) {
            LocalStoreFailure.Reason.BindingUnavailable -> "设备保护信息暂时无法读取，请解锁设备后重试。"
            LocalStoreFailure.Reason.BindingMalformed, LocalStoreFailure.Reason.BindingInvalidated,
            LocalStoreFailure.Reason.BindingMismatch -> "无法确认本机数据的安装与账号归属。原有数据已保留。"
            LocalStoreFailure.Reason.StoreUnavailable -> "本机数据库暂时无法读取。原有数据已保留。"
        })
        Spacer(Modifier.height(24.dp))
        if (busy) { CircularProgressIndicator(); Text(if (recovery.phase == LocalRecoveryPhase.Preparing) "正在检查恢复条件…" else "正在保留副本并恢复…") }
        recovery.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = retry, enabled = resumed && !busy) { Text("重试打开") }
        if (reason != LocalStoreFailure.Reason.BindingUnavailable)
            OutlinedButton(onClick = prepare, enabled = resumed && !busy) { Text("保留副本并重新同步") }
        TextButton(onClick = signOut, enabled = resumed && !busy) { Text("退出当前账号") }
    }
    recovery.preview?.takeIf { resumed }?.let { preview ->
        AlertDialog(onDismissRequest = dismiss, title = { Text("保留副本并重新同步？") },
            text = { Text((if (preview.continuesRecovery) "将继续之前未完成的归档，已保留的副本会继续使用。" else "") +
                (if (preview.rebuildsInstallationBinding) "将重建设备保护信息。其他本机账号再次打开时也需要重新核对并同步，原数据会保留。" else "") +
                (if (preview.databaseBytes > 0) "将保留原数据库副本，重新获取服务器上的内容。" else "将重新获取服务器上的内容。") +
                if (preview.includesResources) "本机附件目录也会保留。草稿和未完成任务不会自动恢复。" else "本机草稿和未完成任务不会自动恢复。") },
            confirmButton = { TextButton(onClick = confirm) { Text("确认恢复") } },
            dismissButton = { TextButton(onClick = dismiss) { Text("取消") } })
    }
}

@Composable private fun SignIn(state: AppState, model: AppViewModel,stack: androidx.navigation3.runtime.NavBackStack<androidx.navigation3.runtime.NavKey> = rememberNavBackStack(Route.Home)) {
    var securityEndpoint by rememberSaveable { mutableStateOf(model.initialEndpoint) }
    NavDisplay(backStack = stack, onBack = { if(!state.securityBusy && stack.size > 1) stack.removeLastOrNull() },
        entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
        entryProvider = entryProvider {
            entry<Route.Home> { LoginForm(state, model) { endpoint -> securityEndpoint = endpoint; stack.add(Route.Page(PageKind.Account)) } }
            entry<Route.Page> {
                Scaffold(topBar = { CenterAlignedTopAppBar(title = { Text("账号安全") }, navigationIcon = {
                    IconButton(onClick = { stack.removeLastOrNull() }, enabled = !state.securityBusy) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回登录") }
                }) }) { padding -> Box(Modifier.padding(padding)) {
                    AccountSecurityPage(true, initialAction = PasswordAction.Recover, generateCode = model::generateRecoveryCode) { action, account, current, next, code ->
                        model.performPassword(action, account, current, next, code, securityEndpoint)
                    }
                } }
            }
        })
}

@Composable private fun LoginForm(state: AppState, model: AppViewModel, openSecurity: (String) -> Unit) {
    var account by rememberSaveable { mutableStateOf("") }
    // Password never enters saved state or a ViewModel.
    var password by remember { mutableStateOf("") }
    var register by rememberSaveable { mutableStateOf(false) }
    var handle by rememberSaveable { mutableStateOf("") }
    var name by rememberSaveable { mutableStateOf("") }
    var endpoint by rememberSaveable { mutableStateOf(model.initialEndpoint) }
    var showServer by rememberSaveable { mutableStateOf(false) }
    val invitationTicket by model.invitationInbox.ticket.collectAsState()
    val recovery by model.credentialRecovery.collectAsState()
    val recoveryUnavailable = recovery == CredentialRecoveryUi.Unavailable || recovery == CredentialRecoveryUi.Checking
    val busy = state.session == SessionUi.Authenticating
    Scaffold(topBar = { CenterAlignedTopAppBar(title = { Text(if (register) "注册" else "登录") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).imePadding().testTag("login-form"), horizontalAlignment = Alignment.CenterHorizontally,
            contentPadding = PaddingValues(horizontal = 28.dp, vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Box(Modifier.size(76.dp).clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Outlined.Chat, null, tint = MaterialTheme.colorScheme.onPrimary, modifier = Modifier.size(38.dp))
                }
                Spacer(Modifier.height(24.dp))
                Text(if (register) "开启新的交流" else "欢迎回来", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                Text("让每一次交流，更近一点。", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp))
            }
            if (invitationTicket != null) item {
                Text("收到群邀请，登录后可查看群信息。", modifier = Modifier.testTag("pending-invitation"))
                TextButton(onClick = model.invitationInbox::clear) { Text("忽略邀请") }
            }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().widthIn(max = 500.dp)) {
                    listOf("登录", "注册").forEachIndexed { index, label ->
                        SegmentedButton(selected = register == (index == 1), onClick = { register = index == 1 }, enabled = !busy,
                            shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
                    }
                }
            }
            item { OutlinedTextField(account, { account = it }, label = { Text("账号") }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth().widthIn(max = 500.dp)) }
            item { OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true, enabled = !busy,
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth().widthIn(max = 500.dp)) }
            if (register) {
                item { OutlinedTextField(handle, { handle = it }, label = { Text("公开标识") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
                item { OutlinedTextField(name, { name = it }, label = { Text("显示名称") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
                item { Text("请妥善保存密码。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            state.notice?.let { notice -> item { Text(notice) } }
            state.error?.let { error -> item { Text(error, color = MaterialTheme.colorScheme.error) } }
            item { Button(onClick = { model.login(account, password, register, handle, name, endpoint); password = "" }, enabled = !busy && !recoveryUnavailable && !state.cleanupPending && account.isNotBlank() && password.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("login-submit")) { if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text(if (register) "创建账号" else "登录") } }
            item { TextButton(onClick = { password = ""; openSecurity(endpoint) }, enabled = !busy && !state.cleanupPending) { Text("找回账号与账号安全") } }
            if (state.cleanupPending) item { OutlinedButton(onClick = model::signOut) { Text("重试完成退出登录") } }
            item { TextButton(onClick = { showServer = !showServer }, enabled = !busy) { Text("服务连接设置") } }
            if (showServer) item { OutlinedTextField(endpoint, { endpoint = it }, label = { Text("HTTPS 服务地址") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
            if (BuildConfig.DEBUG && !state.cleanupPending) item { TextButton(onClick = model::demo, enabled = !busy) { Text("体验界面（离线演示）") } }
        }
    }
}

@Composable internal fun SignedIn(state: AppState, session: SessionUi.SignedIn, model: AppViewModel,stack: androidx.navigation3.runtime.NavBackStack<androidx.navigation3.runtime.NavKey> = rememberNavBackStack(Route.Home)) {
    var tab by rememberSaveable { mutableStateOf(Tab.Messages) }
    var menu by remember { mutableStateOf(false) }
    val route = stack.last() as Route
    var localDraftOperation by rememberSaveable { mutableStateOf<String?>(null) }
    var localDraftText by rememberSaveable { mutableStateOf("") }
    val root = route == Route.Home
    val navigationBusy=state.securityBusy || route is Route.ConversationResources && state.conversationResources?.adding==true || route is Route.AvatarResources && state.avatarResources?.submitting==true || route is Route.GroupAvatarCrop && state.groupAvatarEditor?.busy==true || route is Route.AvatarCrop && state.avatarEditor?.operation==AvatarEditorOperation.Saving
    val invitationTicket by model.invitationInbox.ticket.collectAsState()
    val resumed = rememberReadForeground()
    LaunchedEffect(invitationTicket, session, navigationBusy, resumed) {
        if (invitationTicket != null && !session.demo && !navigationBusy && resumed) {
            // Match the iOS root's invitation entry while retaining the shared detail stack.
            tab = Tab.Messages
            val target = Route.Page(PageKind.JoinGroup)
            val existing = stack.indexOf(target)
            if (existing >= 0) while (stack.last() != target) stack.removeLastOrNull()
            else stack.add(target)
        }
    }
    val chatConversation = (route as? Route.Chat)?.let { selected -> state.snapshot.conversations.firstOrNull { it.id.value == selected.room } }
    val titleProfiles = rememberProfilePresentation(if(session.demo) persistentListOf() else listOfNotNull(chatConversation?.presentationKey()).toPersistentList(),state.snapshot.presentationGeneration,route is Route.Chat && !session.demo && chatConversation?.id !in state.snapshot.revokedRooms,session.user,model::openProfiles)
    val title = when (route) {
        Route.Home -> tab.title
        is Route.SendHistory -> "发送记录"
        is Route.SendTasks -> "待发送消息"
        is Route.Chat -> titleProfiles.title(chatConversation,session.demo)
        is Route.LocalDirect -> state.snapshot.directOperations.firstOrNull { it.command.operation == route.operation }?.publicIdentity?.displayName ?: "本地聊天"
        is Route.Profile -> "个人资料"
        is Route.AvatarEditor -> "更换头像"
        is Route.ConversationResources -> "聊天附件"
        is Route.ResourceDetail -> "资源详情"
        is Route.ResourceOwners -> "相关更改"
        is Route.ResourceProfileOwner -> "个人资料更改"
        is Route.ResourceGroupOwner -> "群头像更改"
        is Route.AvatarResources -> "聊天图片"
        is Route.DraftImage -> "草稿图片"
        is Route.MessageImage -> "查看图片"
        is Route.MessageFile -> "查看文件"
        is Route.ComposeContent -> "编辑消息内容"
        is Route.MessagePlayback -> "播放附件"
        is Route.AvatarCrop -> "调整头像"
        is Route.GroupAvatar -> "群头像"
        is Route.GroupAvatarCrop -> "调整群头像"
        is Route.NameEditor -> if(route.target is NameTarget.Contact) "私人备注" else "我的群昵称"
        is Route.EditMessage -> "编辑消息"
        is Route.Forward -> if(route.message == null) "转发记录" else "转发消息"
        is Route.Reactions -> if(route.message == null) "反应操作记录" else "表情反应"
        is Route.Moderation -> "消息审核记录"
        is Route.Reads -> "已读记录"
        is Route.Readers -> "已读详情"
        is Route.Mutations -> "消息操作记录"
        is Route.Settings -> "聊天设置"
        is Route.Members -> "群成员"
        is Route.Invitations -> "邀请与入群申请"
        is Route.Policies -> "群权限"
        is Route.Announcement -> "群公告"
        is Route.Pins -> "置顶消息"
        is Route.Page -> route.page.title
    }
    val push: (Route) -> Unit = { if (stack.lastOrNull() != it) stack.add(it) }
    LaunchedEffect(route) {model.activateResourceBusiness(when(route) {
        is Route.ResourceOwners->ResourceBusinessSelection(ResourceTransferId(ResourceTransferKind.valueOf(route.kind),route.transfer))
        is Route.ResourceProfileOwner->ResourceBusinessSelection(ResourceTransferId(ResourceTransferKind.valueOf(route.kind),route.transfer),route.intent)
        else->null
    })}
    LaunchedEffect(route) {model.activateResourceManagement(route==Route.Page(PageKind.Resources),(route as? Route.ResourceDetail)?.let {ResourceKey(ResourceHome.Room(RoomId(it.room)),it.media)},route==Route.Page(PageKind.Downloads),route==Route.Page(PageKind.UnavailableRetention),route==Route.Page(PageKind.Storage),route==Route.Page(PageKind.Transfers))}
    LaunchedEffect(route) { model.activateConversationActivity(when(route) { is Route.Chat->RoomId(route.room);is Route.ComposeContent->RoomId(route.room);else->null });model.activateMessagePlayback((route as? Route.MessagePlayback)?.let {MessagePlaybackSelection(MediaMessageLocation(RoomId(it.room),MessageId(it.message)),it.media)});model.activateMessageFile((route as? Route.MessageFile)?.let { MessageFileSelection(MediaMessageLocation(RoomId(it.room),MessageId(it.message)),it.media) });model.activateChatComposer(when(route) { is Route.Chat->RoomId(route.room);is Route.ComposeContent->RoomId(route.room);is Route.DraftImage->RoomId(route.room);is Route.ConversationResources->RoomId(route.room);else->null },(route as? Route.DraftImage)?.asset);model.activateChatImages((route as? Route.Chat)?.let { RoomId(it.room) });model.activateMessageImage((route as? Route.MessageImage)?.let { MessageImageSelection(MediaMessageLocation(RoomId(it.room),MessageId(it.message)),it.media) });model.activateGroupAvatarEditor(when(route) { is Route.ResourceGroupOwner->route.operation;is Route.GroupAvatar->route.id;is Route.GroupAvatarCrop->route.id;is Route.AvatarResources->route.id.takeIf { route.groupRoom!=null };else->null },when(route) { is Route.ResourceGroupOwner->RoomId(route.room);is Route.GroupAvatar->RoomId(route.room);is Route.GroupAvatarCrop->RoomId(route.room);is Route.AvatarResources->route.groupRoom?.let { RoomId(it) };else->null },(route as? Route.ResourceGroupOwner)?.let {ResourceTransferId(ResourceTransferKind.valueOf(it.kind),it.transfer)});model.activateAvatarEditor(when(route) { is Route.AvatarEditor->route.id;is Route.AvatarCrop->route.id;is Route.AvatarResources->route.id.takeIf { route.groupRoom==null };else->null });model.activateAvatarResourcePicker((route as? Route.AvatarResources)?.id,(route as? Route.AvatarResources)?.groupRoom?.let { RoomId(it) });model.activateConversationResources((route as? Route.ConversationResources)?.id,(route as? Route.ConversationResources)?.room?.let {RoomId(it)});model.dismissWithdrawal(); model.dismissSocialPrompt(); model.dismissMemberPrompt(); model.dismissCapabilityPrompt(); model.dismissAdministration(); model.dismissMessageModeration(); if (route !is Route.Members && route !is Route.Policies && route !is Route.Announcement && route !is Route.Pins) model.clearMembers() }
    WithdrawalConfirmation(state.withdrawalPrompt, model::confirmWithdrawal, model::dismissWithdrawal)
    SocialConfirmationDialog(state.socialPrompt, model::confirmSocial, model::dismissSocialPrompt)
    MemberConfirmationDialog(state.memberPrompt, session.user, model::confirmMember, model::dismissMemberPrompt)
    MessageModerationConfirmationDialog(state.moderationPrompt, model::confirmMessageModeration, model::dismissMessageModeration)
    AdministrationConfirmationDialog(state.administrationPrompt, model::confirmAdministration, model::dismissAdministration)
    CapabilityConfirmationDialog(state.capabilityPrompt, model::confirmCapability, model::dismissCapabilityPrompt)
    Scaffold(topBar = {
        CenterAlignedTopAppBar(title = { Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (root && tab == Tab.Messages) Text(state.connection, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
        } }, navigationIcon = {
            if (!root) IconButton(onClick = { stack.removeLastOrNull() }, enabled = !navigationBusy) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回") }
            else if (tab == Tab.Messages) IconButton(onClick = { push(Route.Page(PageKind.Connection)) }) { Icon(Icons.Outlined.CloudQueue, "连接状态") }
        }, actions = {
            if (root && tab == Tab.Messages) {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.Add, "更多操作") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    listOf(PageKind.NewChat, PageKind.Groups, PageKind.Search, PageKind.Archived, PageKind.Favorites).forEach { page ->
                        DropdownMenuItem(text = { Text(page.title) }, onClick = { menu = false; push(Route.Page(page)) })
                    }
                }
            } else if (root && tab == Tab.Contacts) IconButton(onClick = { push(Route.Page(PageKind.AddFriend)) }) { Icon(Icons.Outlined.PersonAddAlt, "添加朋友") }
            else if (route is Route.Chat) IconButton(onClick = {
                push(Route.Settings(route.room))
            }) { Icon(Icons.Outlined.MoreHoriz, "聊天设置") }
        })
    }, bottomBar = {
        if (root) NavigationBar {
            Tab.entries.forEach { item -> NavigationBarItem(selected = tab == item, onClick = { tab = item }, modifier = Modifier.testTag("root-tab-${item.name}"),
                icon = { Icon(item.icon, null) }, label = { Text(item.title) }) }
        }
    }) { padding ->
        NavDisplay(backStack = stack, onBack = { if (!navigationBusy && stack.size > 1) stack.removeLastOrNull() },
            modifier = Modifier.fillMaxSize().padding(padding),
            entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
            entryProvider = entryProvider {
                entry<Route.Home> {
                    when (tab) {
                        Tab.Messages -> Conversations(state,session,root,model::openProfiles,push,openGroupAvatar=model::openGroupAvatar,openSummaries=model::openSummaryPage)
                        Tab.Contacts -> Contacts(state,session,root,model::openProfiles,model::openRelationships,push)
                        Tab.Account -> {
                            val key=if(session.demo) null else ProfileKey(session.user,ProfileContext.Relationship)
                            val profile=rememberProfilePresentation(listOfNotNull(key).toPersistentList(),state.snapshot.presentationGeneration,root && !session.demo,session.user,model::openProfiles,avatars=true)
                            Account(session,state.snapshot.ownProfile,push,model::signOut,key?.let { profile.avatars[it] })
                        }
                    }
                }
                entry<Route.GroupAvatar> { destination ->
                    val editor=state.groupAvatarEditor?.takeIf { it.id==destination.id } ?: GroupAvatarEditorState(destination.id,RoomId(destination.room))
                    val image=rememberGroupAvatar(editor.room,state.snapshot.groupAvatarGeneration,route==destination && !session.demo,model::openGroupAvatar)
                    val picker=rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { model.groupAvatarPicked(destination.id,it) }
                    LaunchedEffect(editor.openCrop) { if(editor.openCrop && route==destination) { model.groupAvatarCropOpened(destination.id);push(Route.GroupAvatarCrop(destination.room,destination.id)) } }
                    GroupAvatarScreen(state,editor,route==destination,image.image,
                        pick={ if(model.beginGroupAvatarPick(destination.id)) runCatching { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }.onFailure { model.groupAvatarPickerFailed(destination.id) } },
                        adjust={ push(Route.GroupAvatarCrop(destination.room,destination.id)) },clear={ model.clearGroupAvatarPhoto(destination.id) },
                        refresh={ model.refreshGroupAvatar(destination.id) },remove={ model.saveGroupAvatar(destination.id,true) },action={ id,action -> model.groupAvatarAction(destination.id,id,action) },chatImages={ push(Route.AvatarResources(destination.id,destination.room)) })
                }
                entry<Route.GroupAvatarCrop> { destination ->
                    val editor=state.groupAvatarEditor?.takeIf { it.id==destination.id } ?: GroupAvatarEditorState(destination.id,RoomId(destination.room))
                    LaunchedEffect(editor.submitted) { if(editor.submitted!=null && route==destination) stack.removeLastOrNull() }
                    GroupAvatarCropScreen(state,editor,route==destination,{ model.changeGroupAvatarCrop(destination.id,it) },{ model.saveGroupAvatar(destination.id) },{ model.refreshGroupAvatar(destination.id) })
                }
                entry<Route.AvatarEditor> { destination ->
                    val editor=state.avatarEditor?.takeIf { it.id==destination.id } ?: AvatarEditorState(destination.id)
                    val picker=rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> model.avatarPicked(destination.id,uri) }
                    val camera=rememberCameraCaptureLauncher { success -> model.avatarPictureTaken(destination.id,success) }
                    val avatarKey=if(session.demo) null else ProfileKey(session.user,ProfileContext.Relationship)
                    val avatarProfiles=rememberProfilePresentation(listOfNotNull(avatarKey).toPersistentList(),state.snapshot.presentationGeneration,route==destination && !session.demo,session.user,model::openProfiles,avatars=true)
                    LaunchedEffect(editor.openCrop) { if(editor.openCrop && route==destination) { model.avatarCropOpened(destination.id);push(Route.AvatarCrop(destination.id)) } }
                    AvatarEditorScreen(state,editor,route==destination,
                        pick={ if(model.beginAvatarPick(destination.id)) runCatching { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }.onFailure { model.avatarPickerFailed(destination.id) } },
                        adjust={ push(Route.AvatarCrop(destination.id)) },refresh={ model.refreshAvatarProfile(destination.id) },remove={ model.removeAvatar(destination.id) },
                        resume={ model.resumeAvatarIntent(destination.id,it) },discard={ model.discardAvatarIntent(destination.id,it) },clearPhoto={ model.clearAvatarPhoto(destination.id) },
                        camera={ model.takeAvatarPicture(destination.id) { camera(it) } },avatar=avatarKey?.let { avatarProfiles.avatars[it] },chatImages={ push(Route.AvatarResources(destination.id)) })
                }
                entry<Route.ConversationResources> {destination->
                    val picker=state.conversationResources?.takeIf {it.id==destination.id} ?: ConversationResourcePickerState(destination.id,RoomId(destination.room))
                    LaunchedEffect(picker.added) {if(picker.added && route==destination) stack.removeLastOrNull()}
                    ConversationResourcePickerScreen(state,picker,route==destination,{text,category->model.searchConversationResources(destination.id,text,category)},
                        {model.pageConversationResources(destination.id,it)},{model.reloadConversationResources(destination.id)},{model.chooseConversationResource(destination.id,it)},
                        {model.confirmConversationResource(destination.id)},{model.dismissConversationResource(destination.id)})
                }
                entry<Route.AvatarResources> { destination ->
                    val picker=state.avatarResources?.takeIf { it.id==destination.id && it.targetRoom?.value==destination.groupRoom } ?: AvatarResourcePickerState(destination.id,targetRoom=destination.groupRoom?.let { RoomId(it) })
                    LaunchedEffect(picker.submitted) { if(picker.submitted!=null && route==destination) stack.removeLastOrNull() }
                    AvatarResourcePickerScreen(state,picker,route==destination,{ model.searchAvatarResources(destination.id,it) },
                        { model.nextAvatarResources(destination.id) },{ model.previousAvatarResources(destination.id) },{ model.reloadAvatarResources(destination.id) },
                        { model.chooseAvatarResource(destination.id,it) },{ model.refreshAvatarResourceProfile(destination.id) },{ model.confirmAvatarResource(destination.id) },{ model.dismissAvatarResource(destination.id) },{ model.visibleAvatarResources(destination.id,it) })
                }
                entry<Route.AvatarCrop> { destination ->
                    val editor=state.avatarEditor?.takeIf { it.id==destination.id } ?: AvatarEditorState(destination.id)
                    LaunchedEffect(editor.submitted) { if(editor.submitted!=null && route==destination) stack.removeLastOrNull() }
                    AvatarCropScreen(state,editor,route==destination,{ model.changeAvatarCrop(destination.id,it) },{ model.saveAvatar(destination.id) },{ model.refreshAvatarProfile(destination.id) })
                }
                entry<Route.DraftImage> { destination ->
                    val selection=remember(destination) { DraftImageSelection(RoomId(destination.room),destination.asset) }
                    DraftImageScreen(state.draftImage,selection,route==destination,{ model.retryDraftImage(selection) })
                }
                entry<Route.ComposeContent> {destination->
                    ComposeContentScreen(state,RoomId(destination.room),route==destination,model::editChatContent,model::setChatMentions,model::openMessageSources)
                }
                entry<Route.MessagePlayback> { destination ->
                    val selection=remember(destination) {MessagePlaybackSelection(MediaMessageLocation(RoomId(destination.room),MessageId(destination.message)),destination.media)}
                    MessagePlaybackScreen(state,state.messagePlayback,selection,route==destination,{model.playbackPlayer(selection,it)},{model.togglePlayback(selection)},{model.seekPlayback(selection,it)},{model.retryPlayback(selection)},{push(Route.MessageFile(destination.room,destination.message,destination.media))},openSources=model::openMessageSources)
                }
                entry<Route.MessageFile> { destination ->
                    val selection=remember(destination) { MessageFileSelection(MediaMessageLocation(RoomId(destination.room),MessageId(destination.message)),destination.media) }
                    MessageFileScreen(state,state.messageFile,selection,route==destination,{ model.beginFileSave(selection) },{ id,uri->model.fileSaveResult(selection,id,uri) },{ model.filePickerFailed(selection,it) },{ model.retryMessageFile(selection) },{ model.fileOpenFailed(selection) },present={model.presentMessageFile(selection,it)},claim={model.claimFilePresentation(selection,it)},launched={model.filePresentationLaunched(selection,it)},returned={model.filePresentationReturned(selection,it)},failed={model.filePresentationFailed(selection,it)},play={push(Route.MessagePlayback(destination.room,destination.message,destination.media))},openSources=model::openMessageSources)
                }
                entry<Route.MessageImage> { destination ->
                    val selection=remember(destination) { MessageImageSelection(MediaMessageLocation(RoomId(destination.room),MessageId(destination.message)),destination.media) }
                    MessageImageScreen(state,state.messageImage,selection,route==destination,{ model.retryMessageImage(selection) },{ model.loadOriginalImage(selection) },openSources=model::openMessageSources)
                }
                entry<Route.LocalDirect> { destination ->
                    LocalDirectScreen(destination.operation, state, route == destination, model::sendLocalDirect,
                        model::prepareLocalDirectMessages, model::retryLocalDirect, model::enterLocalDirectRoom,
                        initialDraft = localDraftText.takeIf { localDraftOperation == destination.operation }.orEmpty()) { next, draft ->
                        if (stack.lastOrNull() == destination) {
                            localDraftOperation = (next as? DirectConversationDestination.Pending)?.operation
                            localDraftText = if (localDraftOperation != null) draft else ""
                            stack[stack.lastIndex] = next.route()
                        }
                    }
                }
                entry<Route.Chat> { destination -> Chat(state, session, RoomId(destination.room), model::send, model::preparePin, { push(Route.Announcement(destination.room)) }, { push(Route.Pins(destination.room)) }, model::changeFavorite, { message -> push(Route.EditMessage(destination.room, message.value)) }, { message -> model.prepareWithdrawal(RoomId(destination.room), message) }, { message -> push(Route.Reactions(destination.room, message.value)) }, { message -> push(Route.Forward(destination.room, message.value)) }, moderate = { message -> model.prepareMessageModeration(RoomId(destination.room), message) }, active = route == destination, reportRead = model::reportRead, readers = { message -> push(Route.Readers(destination.room,message.value)) },openProfiles = model::openProfiles,openImage={ message,media -> push(Route.MessageImage(destination.room,message.value,media)) },visibleImages=model::visibleChatImages,retryImage=model::retryChatImage,composer=if(model.hasChatComposer()) model else null,openSendTasks={ push(Route.SendTasks(destination.room)) },openDraftImage={ asset -> push(Route.DraftImage(destination.room,asset)) },openFile={ message,media -> push(Route.MessageFile(destination.room,message.value,media)) },openPlayback={message,media->push(Route.MessagePlayback(destination.room,message.value,media))},openContent={push(Route.ComposeContent(destination.room))},openChatResources={push(Route.ConversationResources(destination.room))},reply={message->state.chatComposer?.takeIf {it.room.value==destination.room}?.let {model.replyChatDraft(it.id,message)}},openTimeline=model::openTimelinePage,focusMessage=destination.focus?.let {MessageId(it)}) }
                entry<Route.SendHistory> { destination -> val scope=rememberCoroutineScope();SendHistoryScreen(state,RoomId(destination.room),route==destination,model::openSendHistory,{push(Route.Chat(destination.room,focus=it.value))},{push(Route.SendTasks(destination.room))},{operation->scope.launch {model.resumeSendConfirmation(RoomId(destination.room),operation)}},{operation->scope.launch {model.replaceUnsentText(RoomId(destination.room),operation)}},{operation->scope.launch {model.abandonUnsentText(RoomId(destination.room),operation)}}) }
                entry<Route.ResourceOwners> {destination->
                    val selection=remember(destination) {ResourceBusinessSelection(ResourceTransferId(ResourceTransferKind.valueOf(destination.kind),destination.transfer))}
                    ResourceBusinessRoute(state,selection,route==destination,session.demo,model,push)
                }
                entry<Route.ResourceProfileOwner> {destination->
                    val selection=remember(destination) {ResourceBusinessSelection(ResourceTransferId(ResourceTransferKind.valueOf(destination.kind),destination.transfer),destination.intent)}
                    ResourceBusinessRoute(state,selection,route==destination,session.demo,model,push)
                }
                entry<Route.ResourceGroupOwner> {destination->
                    val editor=state.groupAvatarEditor?.takeIf {it.id==destination.operation} ?: GroupAvatarEditorState(destination.operation,RoomId(destination.room),relatedAvailable=false)
                    GroupAvatarScreen(state,editor,route==destination,null,{},{},{},{model.refreshGroupAvatar(destination.operation)},{},
                        {id,action->model.groupAvatarAction(destination.operation,id,action)},focused=destination.operation)
                }
                entry<Route.ResourceDetail> {destination->
                    val key=remember(destination) {ResourceKey(ResourceHome.Room(RoomId(destination.room)),destination.media)}
                    val detail=state.resourceDetail?.takeIf {it.key==key} ?: ResourceDetailState(key)
                    ResourceDetailScreen(detail,route==destination && !session.demo && RoomId(destination.room) !in state.snapshot.revokedRooms,
                        {model.retainResource(key,it)},{model.reloadResourceDetails(key)},{model.pageResourceSources(key,it)},
                        {push(Route.Chat(it.room.value,it.message.value))},{push(Route.MessageFile(it.room.value,it.message.value,destination.media))},
                        {model.downloadResource(key)},{push(Route.Page(PageKind.Downloads))})
                }
                entry<Route.SendTasks> { destination -> SendTasksScreen(state,RoomId(destination.room),route==destination,{ model.retryAttachmentSend(RoomId(destination.room),it) },{ model.discardAttachmentSend(RoomId(destination.room),it) }) }
                entry<Route.Profile> { destination ->
                    val scope = rememberCoroutineScope()
                    var busy by remember { mutableStateOf(false) }
                    val contact = state.snapshot.contacts.firstOrNull { it.id.value == destination.user }
                    val target = UserId(destination.user)
                    val profileKey = destination.presentationKey(session.demo)
                    val profiles = rememberRouteProfile(destination,state,session,route==destination,model::openProfiles)
                    val name = if(session.demo) contact?.name ?: "朋友" else profiles.name(target,requireNotNull(profileKey).context)
                    Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Avatar(name, 76,profileKey?.let { profiles.avatars[it] })
                        Text(name, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(16.dp))
                        (if(session.demo) contact?.handle else profileKey?.let {profiles.identity(it)}?.handle?.value)?.takeIf { it.isNotBlank() }?.let { Text("@$it", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Button(onClick = {
                            busy = true
                            scope.launch { try { model.openLocalDirect(UserId(destination.user),profileKey?.let {profiles.profiles[it]},profileKey?.let {profiles.identity(it)})?.let { push(it.route()) } } finally { busy = false } }
                        }, enabled = !busy, modifier = Modifier.padding(top = 24.dp)) { Text(if (busy) "正在打开…" else "发消息") }
                        if (!session.demo) TextButton(onClick = { push(Route.Page(PageKind.NewChat)) }) { Text("查看待确认的聊天") }
                        if(!session.demo && contact != null && target != session.user) TextButton(onClick = { push(Route.NameEditor(NameTarget.Contact(target))) }) { Text("设置私人备注") }
                        ProfileSocialActions(UserId(destination.user), state, session, model::changeSocial)
                        TextButton(onClick = { push(Route.Page(PageKind.Requests)) }) { Text("好友申请与操作记录") }
                        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }
                entry<Route.NameEditor> { destination -> NameEditorScreen(destination.target,state,route == destination,model::refreshName,model::saveName,model::retryName,model::discardName) }
                entry<Route.EditMessage> { destination -> MessageEditorPage(RoomId(destination.room), MessageId(destination.message), state, model,active=route==destination) { stack.removeLastOrNull() } }
                entry<Route.Forward> { destination -> ForwardPage(RoomId(destination.room), destination.message?.let { MessageId(it) }, state, model,active = route == destination) { stack.removeLastOrNull() } }
                entry<Route.Reactions> { destination -> MessageReactionsPage(RoomId(destination.room), destination.message?.let { MessageId(it) }, state, model,active=route==destination) }
                entry<Route.Moderation> { destination -> MessageModerationHistoryPage(RoomId(destination.room), state, model) }
                entry<Route.Reads> { destination -> ReadHistoryPage(RoomId(destination.room),state,model::retryRead,model::archiveRead,model::restoreRead) }
                entry<Route.Readers> { destination -> ReadReadersScreen(RoomId(destination.room),MessageId(destination.message),state,session,route == destination,openProfiles = model::openProfiles,openSources=model::openMessageSources,fetch = model::readReaders) }
                entry<Route.Mutations> { destination -> MutationHistoryPage(RoomId(destination.room), state, model,active=route==destination) }
                entry<Route.Invitations> { destination -> InvitationsPage(RoomId(destination.room), state, session, route == destination, model::openInvitations, model::openProfiles) }
                entry<Route.Settings> { destination -> ConversationSettingsPage(RoomId(destination.room), state, model, push,active = route == destination) }
                entry<Route.Members> { destination -> MembersPage(RoomId(destination.room), state, session, model, route == destination, { push(Route.Policies(destination.room)) }, { push(Route.Announcement(destination.room)) },openProfile={push(Route.Profile(it.value,destination.room))}) }
                entry<Route.Announcement> { destination -> AnnouncementPage(RoomId(destination.room), state, model, route == destination) }
                entry<Route.Pins> { destination -> PinsPage(RoomId(destination.room),state,model,active=route==destination,openMessage={push(Route.Chat(destination.room,focus=it.value))}) }
                entry<Route.Policies> { destination -> GroupPoliciesPage(RoomId(destination.room), state, model, route == destination) }
                entry<Route.Page> { Page(it.page, state, session, model, route == it, push) { if (stack.size > 1) stack.removeLastOrNull() } }
            })
    }
}

@Composable internal fun Conversations(state: AppState,session: SessionUi.SignedIn,active: Boolean,openProfiles: () -> ProfilePresentationPage?,push: (Route) -> Unit,archived: Boolean = false,openGroupAvatar: (RoomId)->GroupAvatarPage?={null},openSummaries: ()->ConversationSummaryPage?={null}) {
    val visible = state.snapshot.conversations.filter { it.archived == archived }.toPersistentList()
    val list = rememberLazyListState()
    val summaryRows=visible.filter {it.id !in state.snapshot.revokedRooms}.associate {it.id.value to it.id}.toPersistentMap()
    ConversationSummaryDemand(list,summaryRows,active && !session.demo,session.user,openSummaries)
    val rows = if(session.demo) kotlinx.collections.immutable.persistentMapOf() else visible.mapNotNull { conversation -> conversation.presentationKey()?.let { conversation.id.value to it } }.toMap().toPersistentMap()
    val keys = visiblePresentationKeys(list,rows)
    val groupRows=visible.filter { it.kind==RoomKind.Group && it.id !in state.snapshot.revokedRooms }.associate { it.id.value to it.id }.toPersistentMap()
    val visibleGroups=visibleGroupRooms(list,groupRows)
    val profiles = rememberProfilePresentation(keys,state.snapshot.presentationGeneration,active && !session.demo,session.user,openProfiles,avatars=true)
    LazyColumn(Modifier.fillMaxSize().testTag("conversation-list"),state = list,contentPadding = PaddingValues(bottom = 16.dp)) {
        item { SearchEntry { push(Route.Page(PageKind.Search)) } }
        if (visible.isEmpty()) item { EmptyState(Icons.AutoMirrored.Outlined.Chat, "还没有聊天", "新的交流会出现在这里") }
        items(visible, key = { it.id.value }) { conversation ->
            val label = profiles.title(conversation,session.demo)
            val groupImage=rememberGroupAvatar(conversation.id,state.snapshot.groupAvatarGeneration,active && !session.demo && conversation.id in visibleGroups,openGroupAvatar).image
            ListItem(modifier = Modifier.clickable { push(Route.Chat(conversation.id.value)) },
                colors = ListItemDefaults.colors(containerColor = if (conversation.pinned) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surface),
                headlineContent = { Text(label, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = { Text(conversation.preview.ifEmpty { "开始聊天吧" }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                leadingContent = { Avatar(label,image=if(conversation.kind==RoomKind.Group) groupImage else conversation.presentationKey()?.let { profiles.avatars[it] }) }, trailingContent = {
                    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (conversation.updatedAt > 0) Text(time(conversation.updatedAt), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (conversation.unread > 0) Badge { Text(conversation.unread.toString()) }
                        else if (conversation.muted) Icon(Icons.Outlined.NotificationsOff, "已静音", Modifier.size(16.dp))
                    }
                })
            HorizontalDivider(Modifier.padding(start = 84.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .4f))
        }
    }
}
@Composable internal fun Contacts(state: AppState,session: SessionUi.SignedIn,active: Boolean,openProfiles: () -> ProfilePresentationPage?,openRelationships: () -> RelationshipPageSession?,push: (Route) -> Unit,list: androidx.compose.foundation.lazy.LazyListState = rememberLazyListState()) {
    var query by rememberSaveable(session.user) {mutableStateOf("")}
    val searchFocus=LocalFocusManager.current
    val resumed=rememberReadForeground();val scope=rememberCoroutineScope();val currentOpen by rememberUpdatedState(openRelationships)
    val demo=remember(session.user,session.demo,state.snapshot.contacts) {if(session.demo) DemoRelationshipPages(state.snapshot.contacts) else null}
    var page by remember(session.user) {mutableStateOf<RelationshipPageSession?>(null)}
    DisposableEffect(active,resumed,session.user,demo) {
        val opened=if(active && resumed) {if(session.demo) RelationshipPageSession(requireNotNull(demo),session.user,scope) else currentOpen()} else null
        page=opened;onDispose {opened?.close();if(page===opened) page=null}
    }
    val value=page?.state?.collectAsState()?.value ?: RelationshipPageState()
    LaunchedEffect(page,state.snapshot.relationships,state.snapshot.presentationGeneration) {page?.refresh()}
    val relationships=value.page.relationships
    val position=rememberContactListPosition(session,query,list,page,value,active && resumed)
    LaunchedEffect(page,query) {page?.update(RelationshipPageRequest(query),position.viewport)}
    val keys = if(session.demo) persistentListOf() else visibleProfileKeys(list,relationships.map {it.target}.toPersistentList(),ProfileContext.Relationship)
    val profiles = rememberProfilePresentation(keys,state.snapshot.presentationGeneration,active && resumed && !session.demo,session.user,openProfiles,avatars=true)
    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(query,{query=it},placeholder={Text("搜索好友")},singleLine=true,leadingIcon={Icon(Icons.Outlined.Search,null)},
            keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={searchFocus.clearFocus()}),
            modifier=Modifier.fillMaxWidth().padding(16.dp).testTag("contacts-search-query"))
        if(value.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        value.feedback?.let {feedback->Row(Modifier.padding(horizontal=16.dp)) {
            Text(feedback,Modifier.weight(1f));TextButton(onClick={page?.retry()},enabled=!value.loading) {Text("重试")}
        }}
        LazyColumn(Modifier.weight(1f).testTag("contacts-list"),state = list) {
            item(key="contacts.requests") { SettingRow("新的朋友", Icons.Outlined.PersonAddAlt) { push(Route.Page(PageKind.Requests)) } }
            item(key="contacts.groups") { SettingRow("群聊", Icons.Outlined.Groups) { push(Route.Page(PageKind.Groups)) } }
            item(key="contacts.heading") { SectionLabel("联系人") }
            if (relationships.isEmpty() && !value.loading && value.feedback==null) item {
                EmptyState(Icons.Outlined.PeopleOutline,if(query.isBlank()) "还没有联系人" else "未找到联系人",if(query.isBlank()) "与朋友建立联系后，会显示在这里" else "按本机已保存的名称或账号搜索")
            }
            items(relationships, key = { it.target.value }) { relationship ->
                val contact=if(session.demo) state.snapshot.contacts.firstOrNull {it.id==relationship.target} else null
                val name = contact?.name ?: profiles.name(relationship.target,ProfileContext.Relationship)
                ListItem(headlineContent = { Text(name) }, supportingContent = { Text(contact?.subtitle() ?: "联系人") }, leadingContent = { Avatar(name,image=if(session.demo) null else profiles.avatars[ProfileKey(relationship.target,ProfileContext.Relationship)]) },
                    modifier = Modifier.testTag("contacts-row-${relationship.target.value}").clickable(enabled=active && resumed) { push(Route.Profile(relationship.target.value)) })
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal=16.dp),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton(onClick={page?.previous()},enabled=value.canPrevious && !value.loading,modifier=Modifier.testTag("contacts-previous")) {Text("上一页")}
            TextButton(onClick={page?.first()},enabled=value.canPrevious && !value.loading,modifier=Modifier.testTag("contacts-first")) {Text("回到开头")}
            TextButton(onClick={page?.next()},enabled=value.page.next!=null && !value.loading,modifier=Modifier.testTag("contacts-next")) {Text("下一页")}
        }
    }
}
@Composable private fun Account(session: SessionUi.SignedIn, profile: ProfileView?, push: (Route) -> Unit, signOut: () -> Unit,avatar: AvatarPresentationBytes?=null) {
    var confirm by remember { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize().testTag("account-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            ListItem(headlineContent = { Text(if (session.demo) "探索者" else profile?.takeIf { it.user == session.user }?.identity?.displayName ?: "我的账号", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold) },
                supportingContent = { Text(if (session.demo) "离线演示 · 数据仅保留在本次体验" else profile?.takeIf { it.user == session.user }?.identity?.handle?.value?.let { "@$it" } ?: session.user.value, maxLines = 2) },
                leadingContent = { Avatar("我",64,avatar) }, modifier = Modifier.padding(vertical = 16.dp))
        }
        item { SectionLabel("个人") }
        item { SettingRow("公开身份", Icons.Outlined.Badge) { push(Route.Page(PageKind.Identity)) } }
        item { SettingRow("收藏", Icons.Outlined.StarOutline) { push(Route.Page(PageKind.Favorites)) } }
        item { SettingRow("资源中心", Icons.Outlined.FolderOpen) { push(Route.Page(PageKind.Resources)) } }
        item { SettingRow("传输任务", Icons.Outlined.CloudQueue) { push(Route.Page(PageKind.Transfers)) } }
        item { SectionLabel("账号与隐私") }
        item { SettingRow("账号安全", Icons.Outlined.Security) { push(Route.Page(PageKind.Account)) } }
        item { SettingRow("隐私设置", Icons.Outlined.LockOpen) { push(Route.Page(PageKind.Privacy)) } }
        item { SettingRow("登录设备", Icons.Outlined.Devices) { push(Route.Page(PageKind.Devices)) } }
        item { OutlinedButton(onClick = { confirm = true }, modifier = Modifier.fillMaxWidth().padding(24.dp)) { Text(if (session.demo) "结束体验" else "退出登录") } }
        item { Text("IM · 让交流更近一点", Modifier.fillMaxWidth().wrapContentWidth(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
    if (confirm) AlertDialog(onDismissRequest = { confirm = false }, title = { Text("退出当前账号？") },
        text = { Text(if (session.demo) "离线演示内容将在退出后清除。" else "将退出本机账号并撤销当前设备会话。") },
        confirmButton = { TextButton(onClick = { confirm = false; signOut() }) { Text("退出") } }, dismissButton = { TextButton(onClick = { confirm = false }) { Text("取消") } })
}

@Composable internal fun Chat(state: AppState, session: SessionUi.SignedIn, room: RoomId, send: suspend (RoomId, String) -> Boolean, pin: (suspend (RoomId, MessageId) -> Unit)? = null, openAnnouncement: (() -> Unit)? = null, openPins: (() -> Unit)? = null, favorite: (suspend (RoomId, MessageId, Boolean) -> Unit)? = null, edit: ((MessageId) -> Unit)? = null, withdraw: ((MessageId) -> Unit)? = null, reactions: ((MessageId) -> Unit)? = null, forward: ((MessageId) -> Unit)? = null, moderate: (suspend (MessageId) -> Unit)? = null, active: Boolean = true, reportRead: (suspend (RoomId,Long) -> Unit)? = null, readers: ((MessageId) -> Unit)? = null,openProfiles: () -> ProfilePresentationPage? = { null },openImage: ((MessageId,String)->Unit)?=null,visibleImages: (RoomId,kotlinx.collections.immutable.PersistentList<ChatImageRequest>)->Unit={ _,_ -> },retryImage: (ChatImageRequest)->Unit={},composer: AppViewModel?=null,openSendTasks: (()->Unit)?=null,openDraftImage: ((String)->Unit)?=null,openFile: ((MessageId,String)->Unit)?=null,openPlayback: ((MessageId,String)->Unit)?=null,openContent: (()->Unit)?=null,reply: ((MessageId)->Unit)?=null,openTimeline: ((RoomId)->ConversationTimelineSession?)?=null,focusMessage: MessageId?=null,openChatResources: (()->Unit)?=null) {
    var draft by rememberSaveable(room.value) { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val revoked = room in state.snapshot.revokedRooms
    val resumed = rememberReadForeground()
    val windowed = !session.demo && openTimeline != null
    val currentOpenTimeline by rememberUpdatedState(openTimeline)
    var timelinePage by remember(room,session.user) { mutableStateOf<ConversationTimelineSession?>(null) }
    DisposableEffect(room,session.user,active,resumed,revoked,windowed) {
        val opened = if(windowed && active && resumed && !revoked) currentOpenTimeline?.invoke(room) else null
        timelinePage = opened
        onDispose { opened?.close(); if(timelinePage === opened) timelinePage = null }
    }
    val timeline = timelinePage?.state?.collectAsState()?.value
    val window = timeline?.window
    val messages = remember(state.snapshot.messages,room,window,windowed,revoked) {
        if(revoked) persistentListOf() else if(!windowed) state.snapshot.messages.filter { it.roomId == room }.toPersistentList()
        else if(window == null || !window.available) persistentListOf() else window.messages.addAll(window.outbox)
    }

    val timelineRows=remember(messages,window,windowed,revoked) {
        if(windowed && !revoked && window?.available==true) window.entries.addAll(window.outbox.map {ConversationTimelineEntry.MessageEntry(it)})
        else messages.map {ConversationTimelineEntry.MessageEntry(it)}.toPersistentList()
    }
    val group = state.snapshot.conversations.firstOrNull { it.id == room }?.kind == RoomKind.Group
    val pinned = if(windowed) window?.pinned.orEmpty() else state.snapshot.pins.filter { it.room == room }.map { it.message }.toSet()
    val listState = rememberLazyListState()
    val peer = state.snapshot.conversations.firstOrNull { it.id == room }?.peer
    val authorRows = if(session.demo) kotlinx.collections.immutable.persistentMapOf() else messages.filter { it.sender != session.user && (group || it.sender == peer) }.associate { it.id.value to ProfileKey(it.sender,ProfileContext.Room(room)) }.toPersistentMap()
    val authorKeys = visiblePresentationKeys(listState,authorRows)
    val authorProfiles = rememberProfilePresentation(authorKeys,state.snapshot.presentationGeneration,active && !session.demo && !revoked,session.user,openProfiles,avatars=true)
    val checkpoint = if(windowed) window?.checkpoint else state.snapshot.readCheckpoints.firstOrNull { it.room == room }
    val latestAvailable = !windowed || timeline?.loaded == true && window?.latest == true
    val timelinePosition=rememberChatTimelinePosition(room,session.user,listState,messages,
        active && resumed && !revoked && (!windowed || timeline?.loaded == true),latestAvailable,timeline?.navigation,timelinePage,rowKeys=timelineRows.map {it.key}.toPersistentList())
    var initialFocusConsumed by rememberSaveable(room.value,focusMessage?.value) {mutableStateOf(false)}
    val openedTimelinePage=timelinePage
    LaunchedEffect(openedTimelinePage,focusMessage) {
        openedTimelinePage?.let { page ->
            if(!initialFocusConsumed && focusMessage!=null) {timelinePosition.focus(focusMessage.value);initialFocusConsumed=true;page.locate(focusMessage);return@let}
            val anchor = timelinePosition.focused ?: timelinePosition.anchor
            if(!timelinePosition.following && anchor != null) {
                if(anchor.startsWith("activity:")) page.locateActivity(anchor.removePrefix("activity:"))
                else page.locate(MessageId(anchor),highlight=timelinePosition.focused != null)
            }
            else page.latest()
        }
    }
    LaunchedEffect(focusMessage,messages,windowed) {
        if(!windowed && !initialFocusConsumed && focusMessage!=null) {
            initialFocusConsumed=true
            val index=messages.indexOfFirst {it.id==focusMessage && !it.withdrawn && !it.redacted}
            if(index>=0) {timelinePosition.focus(focusMessage.value);timelinePosition.move(scope) {listState.scrollToItem(index)}}
            else timelinePosition.unavailable(false)
        }
    }
    LaunchedEffect(openedTimelinePage,timelinePosition.following) { openedTimelinePage?.followLatest(timelinePosition.following) }
    val scrollToLatest: ()->Unit = {
        timelinePosition.latest()
        timelinePage?.latest()
        if(timelineRows.isNotEmpty()) timelinePosition.move(scope) {listState.scrollToItem(timelineRows.lastIndex)}
    }
    val imageAllowed=active && resumed && !session.demo && !revoked
    val imageRequests=remember(messages) { messages.associate { message -> message.id.value to chatImageRequests(message) } }
    val visibleImagesCallback by rememberUpdatedState(visibleImages)
    val imageInterests by remember(listState,imageRequests,imageAllowed) { derivedStateOf {
        if(!imageAllowed) persistentListOf() else listState.layoutInfo.visibleItemsInfo.asSequence()
            .filter { it.offset<listState.layoutInfo.viewportEndOffset && it.offset+it.size>listState.layoutInfo.viewportStartOffset }
            .flatMap { imageRequests[it.key].orEmpty().asSequence() }.distinct().take(12).toPersistentList()
    } }
    LaunchedEffect(room,imageInterests,state.chatImages?.available) { visibleImagesCallback(room,imageInterests) }
    DisposableEffect(room) { onDispose { visibleImagesCallback(room,persistentListOf()) } }
    val report by rememberUpdatedState(reportRead)
    LaunchedEffect(room,active,resumed,revoked,messages,timelineRows,checkpoint,latestAvailable) {
        if(active && resumed && !revoked && report != null) snapshotFlow {
            val visible = listState.layoutInfo.visibleItemsInfo.filter { it.offset < listState.layoutInfo.viewportEndOffset && it.offset+it.size > listState.layoutInfo.viewportStartOffset }
            val sequence = visible.mapNotNull { item -> messages.firstOrNull { it.id.value == item.key }?.roomSequence }.maxOrNull() ?: 0
            sequence to (sequence>0 && latestAvailable && visible.lastOrNull()?.index == timelineRows.lastIndex && !listState.canScrollForward)
        }.distinctUntilChanged().collect { (sequence,latest) ->
            // Bind the latest-end advancement to the snapshot actually rendered, not a newer database checkpoint.
            val applied = checkpoint?.applied ?: 0
            val target = if(latest) maxOf(sequence,minOf(applied,checkpoint?.head ?: applied)) else sequence
            if(target > 0) report?.invoke(room,target)
        }
    }

    Column(Modifier.fillMaxSize().imePadding().background(MaterialTheme.colorScheme.surfaceContainer)) {
        ConversationActivityBanner(state.conversationActivity,room,active && resumed && !session.demo && !revoked,group)
        if(state.moderationLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (revoked) Text("此会话已不可访问，无法发送消息", Modifier.fillMaxWidth().padding(12.dp), color = MaterialTheme.colorScheme.error)
        if (state.snapshot.conversations.firstOrNull { it.id == room }?.historyIncomplete == true)
            Text("部分较早的历史消息已过期，无法恢复", Modifier.fillMaxWidth().padding(10.dp), style = MaterialTheme.typography.labelSmall)
        if (session.demo) Text("离线演示，消息不会发送给真实联系人", Modifier.fillMaxWidth().padding(10.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if(group && !revoked) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            if(openAnnouncement != null) TextButton(onClick = openAnnouncement) { Text("群公告") }
            if(openPins != null) TextButton(onClick = openPins) { Text("置顶消息（${state.snapshot.pins.count {it.room == room}}）") }
        }
        state.snapshot.announcements.firstOrNull { it.room == room && it.body.isNotEmpty() }?.takeIf { !revoked }?.let { announcement ->
            Text(announcement.body, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
        }
        if(windowed && timeline?.loading == true) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(window?.olderCursor != null) TextButton(onClick={timelinePage?.older()},enabled=active && resumed && timeline?.loading != true,
            modifier=Modifier.testTag("chat-older-messages")) {Text("更早的消息")}
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("chat-timeline"), state = listState, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            items(timelineRows,key={it.key}) {entry->
                if(entry is ConversationTimelineEntry.ActivityEntry) {TimelineActivityRow(entry.activity);return@items}
                val message=(entry as ConversationTimelineEntry.MessageEntry).message
                val mine = message.sender == session.user
                var menu by remember(message.id) { mutableStateOf(false) }
                Column(Modifier.fillMaxWidth().testTag("chat-row-${message.id.value}")
                    .background(if(timelinePosition.focused==message.id.value) MaterialTheme.colorScheme.secondaryContainer else androidx.compose.ui.graphics.Color.Transparent),
                    horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
                    if(timelinePosition.focused==message.id.value) Text("已定位到原消息",style=MaterialTheme.typography.labelSmall,modifier=Modifier.testTag("chat-focused-message"))
                    if (!mine) {
                        val author=if(session.demo) state.snapshot.contacts.firstOrNull { it.id==message.sender }?.name ?: "朋友" else if(group || message.sender==peer) authorProfiles.name(message.sender,ProfileContext.Room(room)) else "资料暂不可用"
                        Row(Modifier.padding(bottom=4.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                            Avatar(author,28,if(session.demo || !group && message.sender!=peer) null else authorProfiles.avatars[ProfileKey(message.sender,ProfileContext.Room(room))])
                            Text(author,style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Surface(shape = RoundedCornerShape(16.dp), color = if (mine) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
                        modifier = Modifier.widthIn(max = 320.dp)) { MessageBubbleContent(message,chatImages=state.chatImages?.takeIf { imageAllowed && it.room==room && it.available },showImagePreviews=!session.demo && !revoked,retryImage=retryImage,richActive=active && resumed && !revoked,viewer=session.user,
                            replySource=if(revoked) null else if(windowed) window?.replySources?.get(message.rich?.replyTo) else messages.firstOrNull {it.id==message.rich?.replyTo},jumpReply={
                                if(active && resumed && !revoked) {
                                    if(windowed) message.rich?.replyTo?.let {timelinePage?.locate(it)}
                                    else {
                                        val index=messages.indexOfFirst {it.id==message.rich?.replyTo && !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted}
                                        if(index>=0) {timelinePosition.focus(messages[index].id.value);timelinePosition.move(scope) {listState.scrollToItem(index)}}
                                    }
                                }
                            },openPlayback=if(imageAllowed && !message.withdrawn && !message.redacted && message.delivery==Delivery.Accepted) openPlayback?.let {open->{media->open(message.id,media)}} else null,openFile=if(imageAllowed && !message.withdrawn && !message.redacted && message.delivery==Delivery.Accepted) openFile?.let { open -> { media -> open(message.id,media) } } else null,openImage=if(imageAllowed && !message.withdrawn && !message.redacted && message.delivery==Delivery.Accepted) openImage?.let { open -> { media -> open(message.id,media) } } else null) }
                    if(!revoked && !message.withdrawn && reactions != null) {
                        (if(windowed) window?.reactions.orEmpty() else state.snapshot.reactions).filter { it.room == room && it.message == message.id }.chunked(4).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { row.forEach { summary ->
                                FilterChip(selected = summary.own, onClick = { reactions(message.id) }, label = { Text("${summary.reaction} ${summary.count}") })
                            } }
                        }
                    }
                    if(message.forwardedFrom != null && !message.withdrawn && !revoked) Text("转发的消息", style = MaterialTheme.typography.labelSmall)
                    if(message.id in pinned && !message.withdrawn) Text("已置顶", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                    if(!revoked && !message.withdrawn && message.delivery == Delivery.Accepted && (pin != null || favorite != null || reactions != null || reply != null)) Box {
                        TextButton(onClick = { menu = true }, contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp)) { Text("消息操作", style = MaterialTheme.typography.labelSmall) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            if(reply!=null && message.revision>0) DropdownMenuItem(text={Text("回复消息")},onClick={menu=false;reply(message.id)},enabled=active && resumed && state.chatComposer?.takeIf {it.room==room}?.sendingPolicy?.allowsNewContent!=false)
                            if(forward != null && message.revision > 0) DropdownMenuItem(text = { Text("转发消息") }, onClick = { menu = false; forward(message.id) })
                            if(reactions != null && message.revision > 0) DropdownMenuItem(text = { Text("表情反应") }, onClick = { menu = false; reactions(message.id) })
                            if(mine && message.revision > 0) {
                                if(edit != null) DropdownMenuItem(text = { Text("编辑消息") }, onClick = { menu = false; edit(message.id) })
                                if(withdraw != null) DropdownMenuItem(text = { Text("撤回消息") }, onClick = { menu = false; withdraw(message.id) })
                            }
                            if(group && mine && readers != null && !session.demo) DropdownMenuItem(text = { Text("已读详情") },onClick = { menu = false;readers(message.id) })
                            if(group && moderate != null) DropdownMenuItem(text = { Text("审核移除消息") }, enabled = !state.moderationLoading, onClick = { menu = false; scope.launch { moderate(message.id) } })
                            if(group && pin != null) DropdownMenuItem(text = { Text(if(message.id in pinned) "取消置顶" else "置顶消息") }, onClick = { menu = false; scope.launch { pin(room, message.id) } })
                            if(favorite != null) {
                                val queued = state.snapshot.personalOperations.lastOrNull { it.target is PersonalTarget.Favorite && it.target.room == room && (it.target as PersonalTarget.Favorite).message == message.id && !it.terminal && (it.command != null || it.deadline > System.currentTimeMillis()) }
                                val selected = (queued?.target as? PersonalTarget.Favorite)?.favorited ?: state.snapshot.personalStates.any { (it.target as? PersonalTarget.Favorite)?.let { value -> value.room == room && value.message == message.id && value.favorited } == true }
                                DropdownMenuItem(text = { Text(if(selected) "取消收藏" else "收藏消息") }, onClick = { menu = false; scope.launch { favorite(room, message.id, !selected) } })
                            }
                        }
                    }
                    if (mine) Text(when (message.delivery) { Delivery.Pending -> "等待发送"; Delivery.Accepted -> if(!group && !revoked && !message.withdrawn && message.roomSequence > 0 && PreferencePublicationPolicy.derive(state.snapshot.preferences,state.snapshot.preferenceOperations).directRead && (if(windowed) window?.directRead?.sequence?.let {it >= message.roomSequence} == true else state.snapshot.directReads.any { it.room == room && it.sequence >= message.roomSequence })) "已读" else "已受理"; Delivery.Failed -> "发送被拒绝" },
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
                }
            }
        }
        if(window?.newerBoundary != null) TextButton(onClick={timelinePage?.newer()},enabled=active && resumed && timeline?.loading != true,
            modifier=Modifier.testTag("chat-newer-messages")) {Text("较新的消息")}
        timeline?.feedback?.let { feedback -> Row(verticalAlignment=Alignment.CenterVertically) {
            Text(feedback,Modifier.weight(1f).padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
            TextButton(onClick={timelinePage?.refresh()},enabled=active && resumed && !revoked && !timeline.loading) {Text("重试")}
        } }
        if((!timelinePosition.following || !latestAvailable) && (messages.isNotEmpty() || windowed && timeline?.loaded==true) && !revoked) TextButton(onClick=scrollToLatest,enabled=active && resumed,modifier=Modifier.testTag("chat-return-latest")) {Text("回到最新消息")}
        timelinePosition.feedback?.takeIf {!revoked}?.let {Text(it,Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)}
        state.error?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error) }
        val pendingSends=state.snapshot.sendIntents.count { it.intent.room==room && !it.intent.sourcesReleased }
        if(pendingSends>0 && openSendTasks!=null) TextButton(onClick=openSendTasks,enabled=active && resumed && !session.demo) { Text("待发送消息（$pendingSends）") }
        if(composer!=null && !session.demo) ChatComposerBar(room,state.chatComposer,active && resumed && !revoked,
            composer::editChatDraft,composer::beginChatPhoto,composer::pickedChatPhoto,composer::chatPhotoFailed,composer::removeChatAttachment,{id->scrollToLatest();composer.sendChatDraft(id)},composer::retryChatDraft,
            composer::beginChatDocument,composer::pickedChatDocument,composer::takeChatPicture,composer::capturedChatPicture,composer::pickedChatPhotos,openDraftImage,composer::moveChatAttachment,openContent,{id->composer.replyChatDraft(id,null)},openChatResources)
        else Surface {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(draft, { draft = it }, placeholder = { Text("发送消息…") }, enabled = !revoked, maxLines = 5, modifier = Modifier.weight(1f), shape = RoundedCornerShape(24.dp))
                IconButton(onClick = {
                    val submitted = draft
                    scrollToLatest()
                    submitting = true
                    scope.launch {
                        try { if (send(room, submitted) && draft == submitted) draft = "" }
                        finally { submitting = false }
                    }
                }, enabled = !revoked && draft.isNotBlank() && !submitting) { Icon(Icons.AutoMirrored.Outlined.Send, "发送") }
            }
        }
    }
}

@Composable private fun Page(page: PageKind, state: AppState, session: SessionUi.SignedIn, model: AppViewModel, active: Boolean, push: (Route) -> Unit, back: () -> Unit) {
    when (page) {
        PageKind.Archived -> Conversations(state,session,active,model::openProfiles,push,archived = true,openGroupAvatar=model::openGroupAvatar,openSummaries=model::openSummaryPage)
        PageKind.Search -> MessageSearchScreen(state,session,active,model::openMessageSearch,model::openProfiles) {
            push(Route.Chat(it.room.value,it.message.value))
        }
        PageKind.Connection -> Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(Icons.Outlined.CloudQueue, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
            Text(state.connection, style = MaterialTheme.typography.headlineSmall)
            Text(if (session.demo) "当前为离线界面体验。返回登录页后，可连接自己的服务器。" else "前台会自动连接并同步消息；进入后台后关闭实时连接。")
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
        PageKind.NewChat, PageKind.AddFriend -> DiscoveryPage(state, session, active, model::lookup, { identity -> model.openLocalDirect(identity.user, identity = identity) }, model::retryDirect, push, model::changeSocial)
        PageKind.Groups -> GroupsPage(state, model::retryGroup, model::cancelGroup, push,active,model::openGroupAvatar)
        PageKind.CreateGroup -> CreateGroupPage(state, session, active, model::lookup, model::createGroup, back)
        PageKind.JoinGroup -> InvitationsPage(null, state, session, active, model::openInvitations, model::openProfiles, model.invitationInbox)
        PageKind.Requests -> SocialRequestsPage(state, session, active, model::openRelationships, model::openProfiles, model::changeSocial, model::prepareSocialProposal, model::discardSocial, model::retrySocial, push)
        PageKind.Privacy -> AccountPrivacyPage(state, session, model, active) { push(Route.Page(PageKind.Blacklist)) }
        PageKind.Blacklist -> BlockedUsersPage(state, model::changeSocial, push)
        PageKind.Favorites -> FavoritesPage(state, model, push,active = active)
        PageKind.Devices -> DevicesPage(model, session.demo, active)
        PageKind.Identity -> OwnProfileScreen(state,active,model::refreshOwnProfile,model::saveOwnProfile,model::retryOwnProfile,model::reapplyOwnProfile,model::discardOwnProfile) { push(Route.AvatarEditor(java.util.UUID.randomUUID().toString())) }
        PageKind.Account -> AccountSecurityPage(active, session.demo, generateCode = model::generateRecoveryCode) { action, account, current, next, code -> model.performPassword(action, account, current, next, code) }
        PageKind.Resources -> ResourceLibraryScreen(state.resourceLibrary,active,session.demo,model::queryResourceLibrary,model::pageResourceLibrary,model::reloadResourceLibrary,open={key->
            (key.home as? ResourceHome.Room)?.let {push(Route.ResourceDetail(it.room.value,key.media))}
        },transfers={push(Route.Page(PageKind.Transfers))},downloads={push(Route.Page(PageKind.Downloads))},retentionRelease={push(Route.Page(PageKind.UnavailableRetention))},storage={push(Route.Page(PageKind.Storage))},
            toggleSelection=model::toggleResourceSelection,select=model::selectResource,selectPage=model::selectResourcePage,
            previewSelection=model::previewSelectedResourceCleanup,confirmSelection=model::confirmSelectedResourceCleanup,dismissSelection=model::dismissSelectedResourceCleanup,
            retainSelection=model::retainSelectedResources)
        PageKind.Storage -> ResourceStorageScreen(state.resourceStorage,active,session.demo,model::refreshResourceStorage,model::setResourceCacheLimit,{push(Route.Page(PageKind.UnavailableRetention))},{push(Route.Page(PageKind.Downloads))},model::previewResourceCacheCleanup,model::confirmResourceCacheCleanup,model::dismissResourceCacheCleanup,model::setResourceManagedLimit)
        PageKind.UnavailableRetention -> UnavailableRetentionScreen(state.unavailableRetention,active,session.demo,model::previewUnavailableRetention,model::releaseUnavailableRetention,model::dismissUnavailableRetention)
        PageKind.Transfers -> ResourceTransfersScreen(state.resourceTransfers,active,session.demo,model::queryTransfers,model::pageTransfers,model::reloadTransfers,
            model::controlTransfer,model::selectTransfers,model::selectTransfer,model::selectTransferPage,model::retryTransfers,
            model::confirmTransferCancellation,model::dismissTransferCancellation,
            open={key->(key.home as? ResourceHome.Room)?.let {push(Route.ResourceDetail(it.room.value,key.media))}},
            related={id,usage->when(usage) {
                is ResourceUsage.Attachment->push(Route.SendHistory(usage.room.value))
                ResourceUsage.UserAvatar,is ResourceUsage.GroupAvatar->push(Route.ResourceOwners(id.kind.name,id.value))
            }},background=state.resourceBackground,startBackground=model::startResourceBackground,stopBackground=model::stopResourceBackground)
        PageKind.Downloads -> ResourceDownloadsScreen(state.resourceDownloads,active,session.demo,model::controlDownload,model::reloadDownloads,open={key->
            (key.home as? ResourceHome.Room)?.let {push(Route.ResourceDetail(it.room.value,key.media))}
        },network=model::setDownloadNetwork)
    }
}

@Composable private fun SearchEntry(onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Outlined.Search, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
            Text("搜索", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
@Composable private fun SettingRow(title: String, icon: ImageVector, onClick: () -> Unit) {
    ListItem(headlineContent = { Text(title) }, leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        trailingContent = { Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline) }, modifier = Modifier.clickable(onClick = onClick))
}
@Composable private fun SectionLabel(text: String) { Text(text, Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).padding(horizontal = 20.dp, vertical = 12.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
@Composable private fun EmptyState(icon: ImageVector, title: String, description: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 56.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.outline)
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(description, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
private fun time(milliseconds: Long): String = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(milliseconds))

@Composable internal fun DiscoveryPage(state: AppState, session: SessionUi.SignedIn, active: Boolean,
    resolve: suspend (String) -> IdentityLookup?, open: suspend (PublicIdentity) -> DirectConversationDestination?,
    retry: suspend (String) -> Unit, push: (Route) -> Unit,
    changeSocial: (suspend (UserId, SocialAction) -> Unit)? = null) {
    var query by rememberSaveable { mutableStateOf("") }
    var result by remember { mutableStateOf<IdentityLookup?>(null) }
    var busy by remember { mutableStateOf(false) }
    var expired by remember { mutableStateOf(false) }
    var lookupGeneration by remember { mutableLongStateOf(0) }
    val scope = rememberCoroutineScope()
    val currentActive by rememberUpdatedState(active)
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Discovery permission does not survive a background transition or navigation away.
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) { result = null; lookupGeneration++ } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(active) { if (!active) { result = null; lookupGeneration++ } }
    LaunchedEffect(result) {
        val value = result ?: return@LaunchedEffect
        while (value.valid()) delay(((value.deadlineNanos - System.nanoTime()) / 1_000_000).coerceIn(1, 60_000))
        if (result == value) { result = null; expired = true }
    }
    LazyColumn(Modifier.fillMaxSize().imePadding(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("通过公开标识查找朋友", style = MaterialTheme.typography.titleMedium) }
        item { OutlinedTextField(query, { query = it; result = null; expired = false; lookupGeneration++ }, label = { Text("公开标识，例如 @lin") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
        item { Button(onClick = {
            val requested = query
            val generation = lookupGeneration
            result = null; expired = false; busy = true
            scope.launch {
                try {
                    val found = resolve(requested)
                    if (lookupGeneration == generation && currentActive && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && found?.valid() == true) result = found
                } finally { busy = false }
            }
        }, enabled = !busy && query.isNotBlank()) { Text(if (busy) "处理中…" else "查找") } }
        if (expired) item { Text("查询结果已过期，请重新查找", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        result?.takeIf { it.valid() }?.let { found ->
            item {
                ListItem(headlineContent = { Text(found.identity.displayName) }, supportingContent = { Text("@${found.identity.handle.value}") }, leadingContent = { Avatar(found.identity.displayName) })
                Button(onClick = {
                    if (!found.valid()) { result = null; expired = true; return@Button }
                    busy = true
                    scope.launch {
                        try { open(found.identity)?.let { destination -> result = null; push(destination.route()) } }
                        finally { busy = false }
                    }
                }, enabled = !busy && found.identity.user != session.user) { Text(if (found.identity.user == session.user) "这是你自己" else "发消息") }
                if (changeSocial != null && found.identity.user != session.user) {
                    val relationship = state.snapshot.relationships.firstOrNull { it.target == found.identity.user }
                    val pending = state.snapshot.socialOperations.any { !it.terminal && it.command.target == found.identity.user && it.command.action.kind == "relationship" }
                    if (relationship == null && !pending) OutlinedButton(onClick = {
                        if (!found.valid()) { result = null; expired = true; return@OutlinedButton }
                        busy = true
                        scope.launch { try { changeSocial(found.identity.user, SocialAction.Request) } finally { busy = false } }
                    }, enabled = !busy) { Text("添加朋友") }
                    else Text(when { pending -> "申请正在确认，可在操作记录中查看"; relationship?.state == RelationshipState.Accepted -> "已是好友"; else -> "已有好友申请，请查看新的朋友" })
                }
            }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        if (changeSocial != null) item { TextButton(onClick = { result = null; push(Route.Page(PageKind.Requests)) }) { Text("好友申请与操作记录") } }
        if (state.snapshot.directOperations.isNotEmpty()) item { SectionLabel("聊天请求") }
        items(state.snapshot.directOperations, key = { it.command.operation }) { work ->
            ListItem(headlineContent = { Text(work.publicIdentity?.displayName ?: "用户 ${work.command.target.value.takeLast(8)}") },
                supportingContent = { Text(when(work.status) {
                    DirectWorkStatus.Pending -> if (work.processing) "服务器正在处理，稍后自动确认" else "等待确认，会自动重试"
                    DirectWorkStatus.NeedsAttention -> "结果尚未确认，请重试查询"
                    DirectWorkStatus.Opened -> "会话已就绪"
                    DirectWorkStatus.Rejected -> "服务器拒绝了这次请求"
                    DirectWorkStatus.Closed -> "请求已关闭，可以重新发起"
                }) }, trailingContent = {
                    if (work.status == DirectWorkStatus.Opened) TextButton(onClick = { result = null; push(Route.LocalDirect(work.command.operation)) }) { Text("打开") }
                    else TextButton(onClick = { result = null; push(Route.LocalDirect(work.command.operation)) }) { Text("打开聊天") }
                    if (work.status == DirectWorkStatus.NeedsAttention) TextButton(onClick = {
                        busy = true
                        scope.launch { try { retry(work.command.operation) } finally { busy = false } }
                    }, enabled = !busy) { Text("重试") }
                })
        }
        if (state.snapshot.contacts.isNotEmpty()) item { SectionLabel("联系人") }
        items(state.snapshot.contacts, key = { "contact/${it.id.value}" }) { contact ->
            ListItem(headlineContent = { Text(contact.name) }, supportingContent = { Text(contact.subtitle()) },
                modifier = Modifier.clickable { result = null; push(Route.Profile(contact.id.value)) }, leadingContent = { Avatar(contact.name) })
        }
    }
}

@Composable private fun ResourceBusinessRoute(state:AppState,selection:ResourceBusinessSelection,active:Boolean,demo:Boolean,model:AppViewModel,push:(Route)->Unit) {
    val value=state.resourceBusiness?.takeIf {it.selection==selection} ?: ResourceBusinessState(selection)
    ResourceBusinessScreen(value,active,demo,model::pageResourceBusiness,model::reloadResourceBusiness,model::openResourceBusiness,
        model::resumeResourceProfile,model::reviewResourceProfile,model::confirmResourceProfile,model::dismissResourceProfile,model::consumeResourceBusinessOpen) {owner->
        when(owner) {
            is ResourceBusinessOwner.Profile->push(Route.ResourceProfileOwner(selection.transfer.kind.name,selection.transfer.value,owner.id))
            is ResourceBusinessOwner.Group->push(Route.ResourceGroupOwner(selection.transfer.kind.name,selection.transfer.value,owner.room.value,owner.id))
        }
    }
}
