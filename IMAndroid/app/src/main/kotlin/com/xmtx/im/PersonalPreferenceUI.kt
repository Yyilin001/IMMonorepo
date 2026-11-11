package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.launch

@Composable internal fun ConversationSettingsPage(room: RoomId, state: AppState, model: AppViewModel, push: (Route) -> Unit,active: Boolean = true) {
    val conversation = state.snapshot.conversations.firstOrNull { it.id == room }
    val profiles = rememberConversationTitles(null,state,active,persistentMapOf(room.value to room),model::openProfiles)
    val demo = (state.session as? SessionUi.SignedIn)?.demo == true
    val confirmed = state.snapshot.personalStates.firstOrNull { it.target.key == PersonalTarget.Conversation(room).key }?.target as? PersonalTarget.Conversation
    val pending = state.snapshot.personalOperations.lastOrNull { it.target is PersonalTarget.Conversation && it.target.room == room && !it.terminal && (it.command != null || it.deadline > System.currentTimeMillis()) }
    val selected = pending?.target as? PersonalTarget.Conversation ?: confirmed ?: PersonalTarget.Conversation(room, conversation?.pinned ?: false, conversation?.archived ?: false, if(conversation?.muted == true) Long.MAX_VALUE else 0)
    val scope = rememberCoroutineScope(); var busy by remember { mutableStateOf(false) }; var muteMenu by remember { mutableStateOf(false) }
    fun change(patch: ConversationPatch) { busy = true; scope.launch { try { model.changeConversation(room, patch) } finally { busy = false } } }
    val enabled = room !in state.snapshot.revokedRooms && conversation != null && !busy
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text(profiles.title(conversation,demo), style = MaterialTheme.typography.titleLarge) }
        if(!enabled && !busy) item { Text("此会话当前不可修改", color = MaterialTheme.colorScheme.error) }
        item { Text("会话整理", style = MaterialTheme.typography.titleMedium) }
        item { ListItem(headlineContent = { Text("置顶聊天") }, trailingContent = { Switch(selected.pinned, { change(ConversationPatch(pinned = it)) }, enabled = enabled, modifier = Modifier.semantics { contentDescription = "置顶聊天" }) }) }
        item { ListItem(headlineContent = { Text("隐藏聊天") }, supportingContent = { Text("隐藏后可从消息页的“隐藏的聊天”找回") }, trailingContent = { Switch(selected.archived, { change(ConversationPatch(archived = it)) }, enabled = enabled, modifier = Modifier.semantics { contentDescription = "隐藏聊天" }) }) }
        item { Box {
            ListItem(headlineContent = { Text("消息免打扰") }, supportingContent = { Text(if(selected.muteUntil > System.currentTimeMillis()) "已开启" else "未开启") }, modifier = Modifier.clickable(enabled = enabled) { muteMenu = true })
            DropdownMenu(muteMenu, { muteMenu = false }) {
                listOf("1 小时" to 3600000L, "8 小时" to 28800000L, "1 天" to 86400000L, "持续免打扰" to 315576000000L).forEach { (label, duration) ->
                    DropdownMenuItem(text = { Text(label) }, onClick = { muteMenu = false; change(ConversationPatch(muteUntil = System.currentTimeMillis() + duration)) })
                }
                if(selected.muteUntil > System.currentTimeMillis()) DropdownMenuItem(text = { Text("取消免打扰") }, onClick = { muteMenu = false; change(ConversationPatch(muteUntil = 0)) })
            }
        } }
        if(!demo) item { TextButton(onClick = { push(Route.SendHistory(room.value)) },enabled=active && room !in state.snapshot.revokedRooms) { Text("发送记录") } }
        item { TextButton(onClick = { push(Route.Reads(room.value)) }) { Text("已读记录") } }
        item { TextButton(onClick = { push(Route.Mutations(room.value)) }) { Text("消息操作记录") } }
        item { TextButton(onClick = { push(Route.Reactions(room.value)) }) { Text("反应操作记录") } }
        item { TextButton(onClick = { push(Route.Forward(room.value)) }) { Text("转发记录") } }
        if(pending != null) item { Text("显示的是你的最新选择，修改正在等待服务端确认。", style = MaterialTheme.typography.bodySmall) }
        if(conversation?.kind == RoomKind.Group && room !in state.snapshot.revokedRooms) {
            item { HorizontalDivider() }
            item { TextButton(onClick={ push(Route.GroupAvatar(room.value,java.util.UUID.randomUUID().toString())) }) { Text("群头像") } }
            if(!demo) item { TextButton(onClick = { push(Route.NameEditor(NameTarget.Group(room))) }) { Text("我的群昵称") } }
            item { TextButton(onClick = { push(Route.Members(room.value)) }) { Text("群成员") } }
            item { TextButton(onClick = { push(Route.Moderation(room.value)) }) { Text("消息审核记录") } }
            item { TextButton(onClick = { push(Route.Invitations(room.value)) }) { Text("邀请与入群申请") } }
            item { TextButton(onClick = { push(Route.Announcement(room.value)) }) { Text("群公告") } }
            item { TextButton(onClick = { push(Route.Policies(room.value)) }) { Text("群权限") } }
        }
        items(state.snapshot.personalOperations.filter { it.target is PersonalTarget.Conversation && it.target.room == room && it.status != PersonalStatus.Cancelled }.reversed(), key = { it.operation }) { PersonalWorkCard(it, model) }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
@Composable internal fun FavoritesPage(state: AppState, model: AppViewModel, push: (Route) -> Unit,active: Boolean = true,
    open: ()->FavoriteMessageSession?=model::openFavorites) {
    val session=state.session as? SessionUi.SignedIn
    val resumed=rememberReadForeground();val allowed=active && resumed && session!=null
    val currentOpen by rememberUpdatedState(open)
    var page by remember(session) {mutableStateOf<FavoriteMessageSession?>(null)}
    DisposableEffect(session,allowed) {
        val opened=if(allowed && session?.demo==false) currentOpen()?.let {if(it.viewer==session.user) it else {it.close();null}} else null
        page=opened;opened?.latest()
        onDispose {opened?.close();if(page===opened) page=null}
    }
    val result=page?.state?.collectAsState()?.value
    val demo=session?.demo==true
    val values=if(!allowed) persistentListOf() else if(demo) state.snapshot.personalStates
        .filter {(it.target as? PersonalTarget.Favorite)?.favorited==true}.sortedByDescending {it.updatedAt}.mapNotNull {value->
            val favorite=value.target as PersonalTarget.Favorite
            state.snapshot.messages.firstOrNull {it.id==favorite.message && it.roomId==favorite.room && !it.withdrawn && !it.redacted && it.roomId !in state.snapshot.revokedRooms}
                ?.let {FavoriteMessageItem(it.roomId,it.id,it.text,it.createdAt,value.updatedAt)}
        }.toPersistentList() else result?.page?.items?.filter {it.room !in state.snapshot.revokedRooms}?.toPersistentList() ?: persistentListOf()
    val scope=rememberCoroutineScope();val list=androidx.compose.foundation.lazy.rememberLazyListState()
    val profiles=rememberConversationTitles(list,state,allowed,values.associate {it.message.value to it.room}.toPersistentMap(),model::openProfiles)
    LaunchedEffect(result?.selection) {list.scrollToItem(0)}
    Column(Modifier.fillMaxSize()) {
        if(result?.loading==true) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(!demo && allowed) Row(Modifier.padding(horizontal=16.dp)) {
            TextButton({page?.previous()},enabled=result?.page?.previous!=null && result.loading!=true) {Text("上一页")}
            TextButton({page?.latest();scope.launch {list.scrollToItem(0)}},enabled=page!=null && result?.loading!=true) {Text("刷新收藏")}
            TextButton({page?.next()},enabled=result?.page?.next!=null && result.loading!=true) {Text("下一页")}
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("favorites-list"),state=list,contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            result?.feedback?.let {feedback->item {Text(feedback);TextButton({page?.refresh()}) {Text("重试读取收藏")}}}
            if(!demo && allowed && page==null) item {Text("本地收藏暂不可读取，请重新打开页面。")}
            if(values.isEmpty() && (demo || result?.loaded==true)) item {Text("暂无收藏")}
            items(values,key={it.message.value}) {favorite->
                Card(Modifier.fillMaxWidth().testTag("favorite-${favorite.message.value}")) {Column(Modifier.padding(16.dp)) {
                    Text(favorite.text,maxLines=3,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    Text(profiles.title(state.snapshot.conversations.firstOrNull {it.id==favorite.room},demo),style=MaterialTheme.typography.bodySmall)
                    Row {
                        TextButton({push(Route.Chat(favorite.room.value,focus=favorite.message.value))},enabled=allowed) {Text("打开聊天")}
                        TextButton({scope.launch {model.changeFavorite(favorite.room,favorite.message,false)}},enabled=allowed) {Text("取消收藏")}
                    }
                }}
            }
            items(state.snapshot.personalOperations.filter {it.target is PersonalTarget.Favorite && it.status !in setOf(PersonalStatus.Cancelled,PersonalStatus.Committed)}.reversed(),key={"work/${it.operation}"}) {PersonalWorkCard(it,model)}
            state.error?.let {item {Text(it,color=MaterialTheme.colorScheme.error)}}
        }
    }
}
@Composable private fun PersonalWorkCard(work: PersonalWork, model: AppViewModel) {
    val scope = rememberCoroutineScope(); var busy by remember { mutableStateOf(false) }
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(when(val target = work.target) {
            is PersonalTarget.Conversation -> "${if(target.pinned) "置顶" else "不置顶"} · ${if(target.archived) "隐藏" else "显示"} · ${if(target.muteUntil > System.currentTimeMillis()) "免打扰" else "提醒"}"
            is PersonalTarget.Favorite -> if(target.favorited) "收藏消息" else "取消收藏"
        })
        Text(when(work.status) {
            PersonalStatus.Queued -> "修改已保存，等待前一笔操作完成"
            PersonalStatus.Pending -> "正在确认修改结果"
            PersonalStatus.NeedsAttention -> "结果尚未确认，请继续核对"
            PersonalStatus.Committed -> "修改已确认"
            PersonalStatus.Conflicted -> "版本已变化，请同步后重新选择"
            PersonalStatus.Rejected -> "修改被拒绝"
            PersonalStatus.Closed -> "原操作已关闭"
            PersonalStatus.Expired -> "尚未提交的修改已过期，请重新选择"
            PersonalStatus.Cancelled -> "已取消"
        }, style = MaterialTheme.typography.bodySmall)
        Row {
            if(work.status == PersonalStatus.NeedsAttention) TextButton(onClick = { act { model.retryPersonal(work.operation) } }, enabled = !busy) { Text("继续核对") }
            if(!work.terminal && !work.submissionStarted) TextButton(onClick = { act { model.discardPersonal(work.operation) } }, enabled = !busy) { Text("取消修改") }
        }
    } }
}
