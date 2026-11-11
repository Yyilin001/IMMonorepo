package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.launch

internal data class SelectedForwardMessage(val message: MessageId,val revision: Long,val sequence: Long)

@Composable internal fun ForwardPage(room: RoomId, initial: MessageId?, state: AppState, model: AppViewModel, active: Boolean = true,
    openTimeline: (RoomId)->ConversationTimelineSession? = model::openTimelinePage,
    submit: suspend (RoomId,PersistentList<SelectedForwardMessage>,PersistentList<RoomId>)->Boolean = model::forwardMessages,
    back: () -> Unit) {
    var sources by rememberSaveable(room.value, initial?.value, stateSaver = listSaver<PersistentList<SelectedForwardMessage>, String>(
        save = { it.map { source -> "${source.message.value}|${source.revision}|${source.sequence}" } },
        restore = { it.map { value -> value.split('|').let { SelectedForwardMessage(MessageId(it[0]),it[1].toLong(),it[2].toLong()) } }.toPersistentList() })) {
        mutableStateOf(persistentListOf())
    }
    var initialConsumed by rememberSaveable(room.value,initial?.value) {mutableStateOf(false)}
    var anchor by rememberSaveable(room.value,initial?.value) {mutableStateOf<String?>(null)}
    val session=state.session as? SessionUi.SignedIn
    val demo=session?.demo==true
    val revoked=room in state.snapshot.revokedRooms
    var page by remember(room,session?.user) {mutableStateOf<ConversationTimelineSession?>(null)}
    DisposableEffect(active,room,session,revoked) {
        val opened=if(active && !demo && !revoked && initial!=null) openTimeline(room) else null
        page=opened
        onDispose {opened?.close();if(page===opened) page=null}
    }
    val openedPage=page
    val timeline=openedPage?.state?.collectAsState()?.value ?: TimelineViewState()
    LaunchedEffect(openedPage) {
        openedPage?.let {owner ->
            val target=anchor?.let {MessageId(it)} ?: initial
            if(target!=null) owner.locate(target) else owner.latest()
            owner.followLatest(false)
        }
    }
    val messages=if(revoked) persistentListOf() else if(demo) state.snapshot.messages.filter {
        it.roomId==room && !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted && it.revision>0
    }.toPersistentList() else timeline.window.messages.filter {
        !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted && it.revision>0
    }.toPersistentList()
    LaunchedEffect(messages,demo,timeline.loaded) {
        if(demo || timeline.loaded) {
            if(!initialConsumed) {
                messages.firstOrNull {it.id==initial}?.let {sources=persistentListOf(SelectedForwardMessage(it.id,it.revision,it.roomSequence))}
                initialConsumed=true
            }
            if(!demo) timeline.window.messages.firstOrNull()?.let {anchor=it.id.value}
        }
    }
    var targets by rememberSaveable(room.value, initial?.value, stateSaver = listSaver<PersistentList<RoomId>, String>(save = { it.map { id -> id.value } }, restore = { it.map(RoomId::invoke).toPersistentList() })) { mutableStateOf(persistentListOf()) }
    var busy by remember { mutableStateOf(false) }; val scope = rememberCoroutineScope()
    val rooms = state.snapshot.conversations.filter { it.id !in state.snapshot.revokedRooms }
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val profiles = rememberConversationTitles(list,state,active,rooms.associate { "target-${it.id.value}" to it.id }.toPersistentMap(),model::openProfiles)
    val valid = room !in state.snapshot.revokedRooms && sources.isNotEmpty() && targets.isNotEmpty() && targets.all { target -> rooms.any { it.id == target } }
    val works = state.snapshot.forwardOperations.filter { work -> work.command.sources.any { it.room == room } }.reversed()
    fun act(block: suspend () -> Unit) { busy = true; scope.launch { try { block() } finally { busy = false } } }
    LazyColumn(Modifier.fillMaxSize().testTag("forward-list"),state = list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(initial != null) {
            item { Text("已选 ${sources.size} 条消息 · ${targets.size} 个会话", style = MaterialTheme.typography.titleMedium) }
            item { Text("每次最多转发 100 条消息到 10 个会话。保留选中时的版本，最终结果以服务端确认为准。", style = MaterialTheme.typography.bodySmall) }
            if(room !in state.snapshot.revokedRooms) items(messages, key = { "source-${it.id.value}" }) { message ->
                val chosen = sources.any { it.message == message.id }; val stale = sources.any { it.message == message.id && it.revision != message.revision }
                ListItem(headlineContent = { Text(message.text.take(160), maxLines = 2) }, supportingContent = { if(stale) Text("内容已变化；仍保留选中时的版本", color = MaterialTheme.colorScheme.error) },
                    trailingContent = { Checkbox(chosen, { checked -> sources = if(checked) sources.add(SelectedForwardMessage(message.id,message.revision,message.roomSequence)) else sources.filter { it.message != message.id }.toPersistentList() }, enabled = !busy && (chosen || sources.size < 100), modifier = Modifier.semantics { contentDescription = "来源 ${message.id.value}" }) })
            }
            if(!demo) {
                if(timeline.loading) item {LinearProgressIndicator(Modifier.fillMaxWidth())}
                timeline.feedback?.let {feedback -> item {Text(feedback)}}
                if(openedPage==null && active && !revoked) item {Text("本地消息暂不可读取，请返回后重试")}
                item {Row {
                    TextButton(onClick={openedPage?.older()},enabled=!busy && !timeline.loading && timeline.window.olderCursor!=null) {Text("更早的消息")}
                    TextButton(onClick={openedPage?.newer()},enabled=!busy && !timeline.loading && timeline.window.newerBoundary!=null) {Text("较新的消息")}
                    TextButton(onClick={openedPage?.refresh()},enabled=!busy && !timeline.loading && openedPage!=null) {Text("刷新来源")}
                }}
            }
            items(sources.filter {source->messages.none {it.id==source.message}},key={"selected-${it.message.value}"}) {source ->
                val number=sources.indexOf(source)+1
                ListItem(headlineContent={Text("已选消息 $number")},supportingContent={Text("当前页外，已保留原选择")},
                    trailingContent={Row {
                        if(!demo) TextButton(onClick={openedPage?.locate(source.message)},enabled=!busy && !timeline.loading && openedPage!=null,
                            modifier=Modifier.semantics {contentDescription="定位已选消息 $number"}) {Text("定位")}
                        TextButton(onClick={sources=sources.remove(source)},enabled=!busy) {Text("取消选择")}
                    }})
            }
            item { Text("目标会话", style = MaterialTheme.typography.titleMedium) }
            items(rooms, key = { "target-${it.id.value}" }) { conversation ->
                val selected = conversation.id in targets
                val label = profiles.title(conversation,demo)
                ListItem(headlineContent = { Text(label) }, trailingContent = { Checkbox(selected, { checked -> targets = if(checked) targets.add(conversation.id) else targets.remove(conversation.id) }, enabled = !busy && (selected || targets.size < 10), modifier = Modifier.semantics { contentDescription = "目标 ${label}" }) })
            }
            if(!valid && sources.isNotEmpty() && targets.isNotEmpty()) item { Text("来源或目标会话当前不可用，请重新选择。", color = MaterialTheme.colorScheme.error) }
            item { Row {
                Button(enabled = !busy && valid, onClick = { act { if(submit(room, sources, targets)) back() } }) { Text(if(busy) "正在保存…" else "确认转发") }
                TextButton(enabled = !busy, onClick = { sources = persistentListOf(); targets = persistentListOf() }) { Text("清空选择") }
            } }
        }
        item { Text("转发记录", style = MaterialTheme.typography.titleMedium) }
        if(works.isEmpty()) item { Text("暂无转发计划") }
        items(works, key = { it.command.operation }) { work ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${work.command.sources.size} 条消息 → ${work.command.targets.size} 个会话")
                Text("成功 ${work.succeeded} · 拒绝 ${work.rejected} · 取消 ${work.cancelled} · 待确认 ${work.unresolved}", style = MaterialTheme.typography.bodySmall)
                Text(when(work.status) {
                    ForwardStatus.Pending -> if(work.cancelRequested) "正在停止尚未开始的任务" else "正在确认转发结果"
                    ForwardStatus.NeedsAttention -> "请继续核对原计划，避免重复转发"
                    ForwardStatus.Committed -> "计划已结束，内容以目标会话同步结果为准"
                    ForwardStatus.Rejected -> "计划提交被拒绝"
                    ForwardStatus.Closed -> "计划未开始，已关闭"
                    ForwardStatus.Cancelled -> "已在提交前取消"
                    ForwardStatus.Expired -> "计划尚未提交，已过期"
                }, style = MaterialTheme.typography.bodySmall)
                Row {
                    if(work.status == ForwardStatus.NeedsAttention) TextButton(enabled = !busy, onClick = { act { model.retryForward(work.command.operation) } }) { Text("继续核对") }
                    if(!work.terminal && !work.cancelRequested) TextButton(enabled = !busy, onClick = { act { model.cancelForward(work.command.operation) } }) { Text("停止剩余") }
                }
            } }
        }
        state.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
    }
}
