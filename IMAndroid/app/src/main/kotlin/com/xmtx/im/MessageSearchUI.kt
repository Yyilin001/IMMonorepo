package com.xmtx.im

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

@Composable internal fun MessageSearchScreen(app: AppState, session: SessionUi.SignedIn, active: Boolean,
    open: ()->MessageSearchSession?, openProfiles: ()->ProfilePresentationPage?={null}, selected: (MessageSearchHit)->Unit) {
    var query by rememberSaveable {mutableStateOf("")}
    var room by rememberSaveable {mutableStateOf<String?>(null)}
    var sender by rememberSaveable {mutableStateOf<String?>(null)}
    var content by rememberSaveable {mutableStateOf(MessageSearchContent.All)}
    val resumed=rememberReadForeground();val scope=rememberCoroutineScope()
    val currentOpen by rememberUpdatedState(open)
    val demo=remember(session.user,session.demo) {if(session.demo) DemoMessageSearch(app.snapshot.messages) else null}
    var page by remember(session.user) {mutableStateOf<MessageSearchSession?>(null)}
    DisposableEffect(active,resumed,session.user) {
        val opened=if(active && resumed) {if(session.demo) MessageSearchSession(requireNotNull(demo),session.user,scope) else currentOpen()} else null
        page=opened;onDispose {opened?.close();if(page===opened) page=null}
    }
    val value=page?.state?.collectAsState()?.value ?: MessageSearchViewState()
    val openedPage=page
    val request=MessageSearchRequest(query,room?.let {MessageSearchScope.Room(RoomId(it))} ?: MessageSearchScope.All,content,sender?.let {UserId(it)})
    LaunchedEffect(openedPage,request) {openedPage?.update(request)}
    val list=rememberLazyListState()
    val hits=value.page.hits
    val profiles=rememberConversationTitles(list,app,active && resumed,hits.associate {it.message.value to it.room}.toPersistentMap(),openProfiles)
    LaunchedEffect(value.request.cursor,query,room,sender,content) {list.scrollToItem(0)}
    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(query,{query=it},placeholder={Text("搜索本机消息")},leadingIcon={Icon(Icons.Outlined.Search,null)},singleLine=true,
            modifier=Modifier.fillMaxWidth().padding(16.dp).testTag("message-search-query"))
        Row(Modifier.fillMaxWidth().padding(horizontal=16.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            var expanded by remember {mutableStateOf(false)}
            Box {
                OutlinedButton(onClick={expanded=true},modifier=Modifier.testTag("message-search-content")) {Text(content.label())}
                DropdownMenu(expanded,onDismissRequest={expanded=false}) {MessageSearchContent.entries.forEach {kind ->
                    DropdownMenuItem(text={Text(kind.label())},onClick={content=kind;expanded=false})
                }}
            }
            FilterChip(selected=sender==session.user.value,onClick={sender=if(sender==session.user.value) null else session.user.value},label={Text("仅自己")})
            TextButton(onClick={page?.refresh()},enabled=!value.loading && active && resumed) {Text("刷新")}
        }
        if(room!=null || sender!=null && sender!=session.user.value) Row(Modifier.padding(horizontal=16.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            if(room!=null) InputChip(selected=true,onClick={room=null},label={Text("限定会话 · 清除")})
            if(sender!=null && sender!=session.user.value) InputChip(selected=true,onClick={sender=null},label={Text("限定发送者 · 清除")})
        }
        if(session.demo) Text("离线演示，只搜索演示消息",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
        if(value.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(value.indexing) Text("正在建立本地搜索索引…",Modifier.padding(16.dp))
        if(value.page.catchingUp) Text("最近的消息仍在建立索引",Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.labelSmall)
        value.feedback?.let {feedback -> Row(Modifier.padding(horizontal=16.dp)) {
            Text(feedback,Modifier.weight(1f));TextButton(onClick={page?.retry()},enabled=!value.loading) {Text(if(value.restartRequired) "重新搜索" else "重试")}
        }}
        LazyColumn(state=list,modifier=Modifier.weight(1f).testTag("message-search-results")) {
            items(hits,key={it.message.value}) {hit ->
                var actions by remember(hit.message) {mutableStateOf(false)}
                val highlighted=buildAnnotatedString {
                    append(hit.preview.text)
                    hit.preview.ranges.forEach {range ->
                        if(range.offset+range.length<=length) addStyle(SpanStyle(fontWeight=FontWeight.Bold,background=MaterialTheme.colorScheme.secondaryContainer),range.offset,range.offset+range.length)
                    }
                }
                ListItem(headlineContent={Text(highlighted,maxLines=3,overflow=TextOverflow.Ellipsis)},
                    supportingContent={Text(profiles.title(app.snapshot.conversations.firstOrNull {it.id==hit.room},session.demo))},
                    trailingContent={Box {
                        IconButton(onClick={actions=true}) {Icon(Icons.Outlined.MoreVert,"搜索筛选")}
                        DropdownMenu(actions,onDismissRequest={actions=false}) {
                            DropdownMenuItem(text={Text("仅搜索此会话")},onClick={room=hit.room.value;actions=false})
                            DropdownMenuItem(text={Text("仅搜索此发送者")},onClick={sender=hit.sender.value;actions=false})
                        }
                    }},modifier=Modifier.testTag("message-search-hit-${hit.message.value}").clickable(enabled=active && resumed) {selected(hit)})
            }
            if(hits.isEmpty() && !value.loading && !value.indexing && value.feedback==null) item {
                Text(if(query.isEmpty() && content==MessageSearchContent.All && sender==null) "输入关键词，或选择内容类型、发送者" else "没有找到消息",Modifier.padding(24.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal=16.dp),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton(onClick={page?.previous()},enabled=value.canPrevious && !value.loading && !value.restartRequired,modifier=Modifier.testTag("message-search-previous")) {Text("上一页")}
            TextButton(onClick={page?.next()},enabled=value.page.next!=null && !value.loading && !value.restartRequired,modifier=Modifier.testTag("message-search-next")) {Text("下一页")}
        }
    }
}
private fun MessageSearchContent.label()=when(this) {
    MessageSearchContent.All->"全部内容";MessageSearchContent.Media->"附件";MessageSearchContent.Image->"图片"
    MessageSearchContent.Video->"视频";MessageSearchContent.Audio->"语音";MessageSearchContent.File->"文件"
}
/** UI-only demo data never enters the authenticated local index. */
private class DemoMessageSearch(private val messages: PersistentList<Message>): MessageSearchStore {
    override suspend fun searchMessages(viewer: UserId,request: MessageSearchRequest): MessageSearchPage {
        val hits=messages.asSequence().filter {message ->
            !message.withdrawn && !message.redacted && message.text.contains(request.query,ignoreCase=true) &&
                (request.sender==null || request.sender==message.sender) &&
                (request.scope !is MessageSearchScope.Room || (request.scope as MessageSearchScope.Room).room==message.roomId) &&
                request.content==MessageSearchContent.All
        }.sortedByDescending {it.createdAt}.take(request.limit).map {
            MessageSearchHit(it.id,it.roomId,it.sender,it.roomSequence,it.createdAt,it.revision,MessageSearchPreview(it.text))
        }.toPersistentList()
        return MessageSearchPage(hits)
    }
    override suspend fun processMessageSearchIndex(limit: Int)=MessageSearchProgress(true,0,0,1)
    override suspend fun messageSearchProgress()=MessageSearchProgress(true,0,0,1)
    override suspend fun rebuildMessageSearchIndex() = Unit
}
