package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class ConversationResourcePickerState(val id: String,val room: RoomId,val available: Boolean=false,val loading: Boolean=false,
    val category: ResourceCategory=ResourceCategory.All,val search: String="",val positions: PersistentList<ResourceCatalogCursor?> = persistentListOf(null),
    val entries: PersistentList<ResourceCatalogEntry> = persistentListOf(),val next: ResourceCatalogCursor?=null,val selecting: Boolean=false,val adding: Boolean=false,
    val selected: MessageAttachmentSelection?=null,val added: Boolean=false,val feedback: String?=null) {val busy get()=selecting || adding}

internal class ConversationResourcePickerController(val id: String,val room: RoomId,parent: CoroutineScope,private val changes: Flow<Long>,
    private val directory: suspend (ResourceCatalogQuery)->ResourceCatalogPage,private val select: suspend (ResourceKey)->MessageAttachmentSelection,
    private val current: suspend (MessageAttachmentSelection)->Boolean,private val add: suspend (MessageAttachmentSelection)->Unit,
    private val publish: (ConversationResourcePickerState)->Unit) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=ConversationResourcePickerState(id,room);private set
    private var active=false;private var closed=false;private var epoch=0L;private var observer: Job?=null;private var task: Job?=null
    private fun update(body: (ConversationResourcePickerState)->ConversationResourcePickerState) {if(!closed) {state=body(state);publish(state)}}
    private fun valid(value: Long)=!closed && active && value==epoch
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;epoch++;observer?.cancel();task?.cancel()
        update {it.copy(available=value,entries=persistentListOf(),selected=null,loading=false,selecting=false,adding=false)}
        if(value) observe()
    }
    fun search(text: String,category: ResourceCategory=state.category) {
        if(!active || state.busy || text.toByteArray(Charsets.UTF_8).size>255 || text==state.search && category==state.category) return
        update {it.copy(search=text,category=category,positions=persistentListOf(null),selected=null)};observe()
    }
    fun page(next: Boolean) {
        if(!active || state.busy || state.loading) return
        if(next) {val cursor=state.next ?: return;update {it.copy(positions=it.positions.add(cursor))}}
        else {if(state.positions.size==1) return;update {it.copy(positions=it.positions.removeAt(it.positions.lastIndex))}}
        update {it.copy(selected=null)};observe()
    }
    fun reload() {if(active && !state.busy) observe()}
    private fun observe() {
        observer?.cancel();val generation=++epoch
        val query=ResourceCatalogQuery(category=state.category,search=state.search,before=state.positions.last(),limit=30)
        update {it.copy(loading=true,entries=persistentListOf(),next=null,feedback=null)}
        observer=scope.launch {changes.collectLatest {
            try {
                val page=directory(query);val chosen=state.selected;val remains=chosen==null || current(chosen);ensureActive()
                if(valid(generation)) update {it.copy(entries=page.entries.filter {MessageAttachmentSelection.eligible(it.descriptor)}.toPersistentList(),next=page.nextCursor,loading=false,
                    selected=if(remains || it.selected!=chosen) it.selected else null,feedback=if(!remains) "来源已变化，请重新选择" else it.feedback)}
            } catch(e: CancellationException) {throw e} catch(_:Exception) {if(valid(generation)) update {it.copy(loading=false,entries=persistentListOf(),selected=null,feedback="暂时无法读取聊天附件，请刷新重试")}}
        }}
    }
    fun choose(key: ResourceKey) {
        if(!active || state.busy || state.entries.none {it.descriptor.key==key}) return
        val generation=epoch;update {it.copy(selecting=true,selected=null,feedback=null)}
        task=scope.launch {
            try {val value=select(key);check(value.key==key && current(value));ensureActive();if(valid(generation)) update {it.copy(selected=value)}}
            catch(e: CancellationException) {throw e} catch(_:Exception) {if(valid(generation)) update {it.copy(feedback="来源不可用，请刷新后重新选择")}}
            finally {if(valid(generation)) update {it.copy(selecting=false)}}
        }
    }
    fun dismiss() {if(!state.adding) update {it.copy(selected=null)}}
    fun confirm() {
        if(!active || state.busy) return
        val value=state.selected ?: return;val generation=epoch;update {it.copy(adding=true,feedback=null)}
        task=scope.launch {
            try {add(value);ensureActive();if(valid(generation)) update {it.copy(added=true,selected=null)}}
            catch(e: CancellationException) {throw e} catch(_:Exception) {if(valid(generation)) update {it.copy(selected=null,feedback="未能添加，请返回聊天检查草稿后重试")}}
            finally {if(valid(generation)) update {it.copy(adding=false)}}
        }
    }
    fun close() {if(closed) return;closed=true;active=false;epoch++;scope.cancel();state=ConversationResourcePickerState(id,room)}
}

@Composable internal fun ConversationResourcePickerScreen(app: AppState,state: ConversationResourcePickerState,active: Boolean,
    search: (String,ResourceCategory)->Unit,page: (Boolean)->Unit,reload: ()->Unit,choose: (ResourceKey)->Unit,confirm: ()->Unit,dismiss: ()->Unit) {
    val context=LocalContext.current
    val allowed=active && rememberReadForeground() && (app.session as? SessionUi.SignedIn)?.demo==false && state.available && state.room !in app.snapshot.revokedRooms
    val composer=app.chatComposer?.takeIf {it.room==state.room}
    val canAdd=allowed && composer?.available==true && !composer.loading && !composer.preparing && !composer.sending && !composer.picking && !composer.contentLocked && composer.resources.size<10 && composer.sendingPolicy.allowsNewContent
    var text by rememberSaveable(state.id) {mutableStateOf(state.search)}
    LaunchedEffect(text) {search(text,state.category)}
    LaunchedEffect(allowed) {if(!allowed) dismiss()}
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text("添加聊天附件",style=MaterialTheme.typography.titleMedium)
        OutlinedTextField(text,{if(it.toByteArray(Charsets.UTF_8).size<=255) text=it},label={Text("搜索聊天附件")},enabled=allowed && !state.busy,singleLine=true,modifier=Modifier.fillMaxWidth().testTag("conversation-resource-search"))
        Row(horizontalArrangement=Arrangement.spacedBy(4.dp)) {ResourceCategory.entries.forEach {category->
            FilterChip(selected=state.category==category,onClick={search(text,category)},enabled=allowed && !state.busy,label={Text(when(category) {ResourceCategory.All->"全部";ResourceCategory.Image->"图片";ResourceCategory.Video->"视频";ResourceCategory.Audio->"音频";ResourceCategory.File->"文件"})})
        }}
        composer?.sendingPolicy?.restriction?.let {Text(it,style=MaterialTheme.typography.bodySmall)}
        Text("选择已同步的聊天附件（最多 50 MB）。添加后可在草稿中排序，发送时复制附件。",style=MaterialTheme.typography.bodySmall)
        if(state.loading || state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.feedback?.let {Text(it,color=MaterialTheme.colorScheme.error)}
        if(!state.loading && state.entries.isEmpty()) Text("本页暂无可选附件")
        LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {items(state.entries,key={"${it.descriptor.key.home}/${it.descriptor.key.media}"}) {entry->
            OutlinedCard(onClick={choose(entry.descriptor.key)},enabled=canAdd && !state.busy,modifier=Modifier.fillMaxWidth().testTag("conversation-resource-${entry.descriptor.key.media}")) {
                Column(Modifier.padding(16.dp)) {Text(entry.descriptor.displayName);Text(android.text.format.Formatter.formatShortFileSize(context,entry.descriptor.byteCount),style=MaterialTheme.typography.bodySmall)}
            }
        }}
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton({page(false)},enabled=allowed && !state.busy && !state.loading && state.positions.size>1) {Text("上一页")}
            Text("第 ${state.positions.size} 页")
            TextButton({page(true)},enabled=allowed && !state.busy && !state.loading && state.next!=null) {Text("下一页")}
        }
        TextButton(reload,enabled=allowed && !state.busy) {Text("刷新附件")}
    }
    state.selected?.takeIf {allowed}?.let {selection->AlertDialog(onDismissRequest=dismiss,title={Text("添加到当前聊天草稿？")},text={Text("${selection.descriptor.displayName}\n发送时会创建附件副本，原消息保持不变。")},
        confirmButton={TextButton(confirm,enabled=canAdd && !state.busy) {Text(if(state.adding) "正在添加…" else "添加到草稿")}},dismissButton={TextButton(dismiss,enabled=!state.adding) {Text("取消")}})}
}
