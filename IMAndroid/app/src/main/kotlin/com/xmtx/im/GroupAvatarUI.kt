package com.xmtx.im

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.delay
import kotlinx.collections.immutable.toPersistentSet

/** Layout intersection excludes precomposed/prefetched rows. Limits page fan-out independently of data size. */
@Composable internal fun visibleGroupRooms(list: androidx.compose.foundation.lazy.LazyListState,rows: kotlinx.collections.immutable.PersistentMap<String,RoomId>): kotlinx.collections.immutable.PersistentSet<RoomId> =
    remember(list,rows) { derivedStateOf {
        list.layoutInfo.visibleItemsInfo.asSequence().filter { it.offset<list.layoutInfo.viewportEndOffset && it.offset+it.size>list.layoutInfo.viewportStartOffset }
            .mapNotNull { rows[it.key] }.distinct().take(32).toSet().toPersistentSet()
    } }.value

@Composable internal fun rememberGroupAvatar(room: RoomId,generation: String,active: Boolean,open: (RoomId)->GroupAvatarPage?): GroupAvatarDisplay {
    val foreground=rememberReadForeground();val currentOpen by rememberUpdatedState(open)
    var page by remember(room,generation,active,foreground) { mutableStateOf<GroupAvatarPage?>(null) }
    DisposableEffect(room,generation,active,foreground) {
        val value=if(active && foreground) currentOpen(room) else null;page=value
        onDispose { value?.close();if(page===value) page=null }
    }
    return if(active && foreground) page?.state?.collectAsState()?.value ?: GroupAvatarDisplay() else GroupAvatarDisplay()
}
@Composable private fun managementAllowed(state: AppState,editor: GroupAvatarEditorState,active: Boolean): Boolean {
    val foreground=rememberReadForeground()
    val allowed=active && foreground && (state.session as? SessionUi.SignedIn)?.demo==false && editor.room !in state.snapshot.revokedRooms
    val deadline=editor.deadlineNanos
    val fresh by produceState(false,allowed,deadline) {
        value=allowed && deadline?.let { it-System.nanoTime()>0 }==true
        if(value) { delay(((requireNotNull(deadline)-System.nanoTime()+999999)/1000000).coerceAtLeast(1));value=false }
    }
    return allowed && fresh && editor.canManage
}
@Composable internal fun GroupAvatarScreen(state: AppState,editor: GroupAvatarEditorState,active: Boolean,image: AvatarPresentationBytes?,
    pick: ()->Unit,adjust: ()->Unit,clear: ()->Unit,refresh: ()->Unit,remove: ()->Unit,action: (String,GroupAvatarTaskAction)->Unit,chatImages: ()->Unit={},focused:String?=null) {
    val foreground=rememberReadForeground();val demo=(state.session as? SessionUi.SignedIn)?.demo!=false
    val interactive=active && foreground && !demo && !editor.busy && !editor.picking && (focused==null || editor.relatedAvailable)
    val authorized=managementAllowed(state,editor,active)
    val tasks=state.snapshot.groupAvatarIntents.filter { it.command.room==editor.room && it.pending && (focused==null || it.id==focused) }
    var removal by remember { mutableStateOf<Long?>(null) };var discard by remember { mutableStateOf<Pair<String,GroupAvatarTaskAction>?>(null) }
    LaunchedEffect(active,foreground,editor.revision) { removal=null;discard=null }
    LazyColumn(Modifier.fillMaxSize().testTag("group-avatar-page"),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item { Column(Modifier.fillMaxWidth(),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(8.dp)) {
            if(focused==null) Avatar("群",112,image.takeIf { active && foreground && !demo })
            Text(if(focused==null) "群头像" else "本次群头像更改",style=MaterialTheme.typography.titleLarge)
            Text(if(demo) "群头像管理需要登录真实账号。" else if(editor.loading) "正在读取群头像和管理权限…" else if(!authorized) "请刷新管理权限；只有群主可以更改群头像。" else if(focused!=null) "仅处理当前资源关联的这次更改。" else "选择照片并调整显示范围。")
        } }
        if(focused==null) item { Button(onClick=pick,enabled=interactive && authorized && editor.maximumBytes!=null && tasks.isEmpty(),modifier=Modifier.fillMaxWidth()) { Text("从相册选择") } }
        if(focused==null) item { OutlinedButton(onClick=chatImages,enabled=interactive && authorized && tasks.isEmpty() && editor.photo==null,
            modifier=Modifier.fillMaxWidth().testTag("group-avatar-chat-images")) { Text("从聊天图片选择") } }
        if(editor.picking) item { Text("请在系统选择器中选择一张照片") }
        if(editor.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth());Text("正在处理…") }
        editor.photo?.let { photo -> item { Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text("待保存图片");AvatarPhotoCanvas(photo,editor.crop,Modifier.size(140.dp))
            Row { TextButton(adjust,enabled=interactive) { Text("继续调整") };TextButton(clear,enabled=interactive) { Text("取消选图") } }
        } } } }
        item { Row {
            TextButton(refresh,enabled=interactive && !editor.loading) { Text("刷新权限") }
            if(focused==null && editor.hasAvatar) TextButton({ removal=editor.revision },enabled=interactive && authorized && tasks.isEmpty()) { Text("移除群头像") }
        } }
        if(focused!=null && tasks.isEmpty()) item {Text("这次群头像更改已处理或不再持有此资源")}
        if(tasks.isNotEmpty()) item { Text("头像更新",style=MaterialTheme.typography.titleMedium) }
        items(tasks,key={ it.id }) { intent -> Card(Modifier.fillMaxWidth().testTag("group-avatar-task-${intent.id}")) {
            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(when(intent.stage) {
                    GroupAvatarStage.Closed,GroupAvatarStage.NeedsAttention -> "这次头像更改尚未完成"
                    GroupAvatarStage.Preparing -> "正在准备群头像"
                    else -> "正在确认头像更新"
                })
                when {
                    intent.stage==GroupAvatarStage.Closed -> {
                        TextButton({ action(intent.id,GroupAvatarTaskAction.Replace) },enabled=interactive && authorized && (intent.upload==null || editor.maximumBytes!=null)) { Text("按当前群头像重新尝试") }
                        TextButton({ discard=intent.id to GroupAvatarTaskAction.Abandon },enabled=interactive) { Text("取消这次更改") }
                    }
                    !intent.submissionStarted -> {
                        if(intent.stage==GroupAvatarStage.NeedsAttention) TextButton({ action(intent.id,GroupAvatarTaskAction.Retry) },enabled=interactive && authorized) { Text("重新准备") }
                        TextButton({ discard=intent.id to GroupAvatarTaskAction.Cancel },enabled=interactive) { Text("取消这次更改") }
                    }
                    else -> Text("可以离开此页面，恢复连接后会继续确认。")
                }
            }
        } }
        editor.feedback?.let { item { Text(it) } }
    }
    if(removal!=null) AlertDialog(onDismissRequest={ removal=null },title={ Text("移除当前群头像？") },text={ Text("确认后群聊将使用默认头像。") },
        confirmButton={ TextButton({ removal=null;remove() },enabled=interactive && authorized && removal==editor.revision && tasks.isEmpty()) { Text("确认移除") } },dismissButton={ TextButton({ removal=null }) { Text("取消") } })
    discard?.let { (id,kind) -> AlertDialog(onDismissRequest={ discard=null },title={ Text("取消这次更改？") },text={ Text("这次修改保留的原图将释放。") },
        confirmButton={ TextButton({ discard=null;action(id,kind) },enabled=interactive && tasks.any { it.id==id && (kind==GroupAvatarTaskAction.Cancel && !it.submissionStarted || kind==GroupAvatarTaskAction.Abandon && it.stage==GroupAvatarStage.Closed) }) { Text("确认取消") } },dismissButton={ TextButton({ discard=null }) { Text("返回") } }) }
}
@Composable internal fun GroupAvatarCropScreen(state: AppState,editor: GroupAvatarEditorState,active: Boolean,change: (AvatarCrop)->Unit,save: ()->Unit,refresh: ()->Unit) {
    val foreground=rememberReadForeground();val authorized=managementAllowed(state,editor,active)
    val editing=active && foreground && !editor.busy && (state.session as? SessionUi.SignedIn)?.demo==false
    val photo=editor.photo;var ready by remember(photo) { mutableStateOf(false) }
    val pending=state.snapshot.groupAvatarIntents.any { it.command.room==editor.room && it.pending }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        item { Text("移动和缩放照片，调整群头像显示范围。") }
        if(photo==null) item { Text("请返回选择一张照片；未保存的图片不会跨应用重启保留。") }
        else {
            item { AvatarPhotoCanvas(photo,editor.crop,Modifier.widthIn(max=420.dp).fillMaxWidth().aspectRatio(1f),if(editing) change else null) { ready=it } }
            item { Text("缩放");Slider(editor.crop.zoom,{ change(editor.crop.copy(zoom=it)) },enabled=editing,valueRange=1f..5f,modifier=Modifier.testTag("group-avatar-crop-zoom")) }
            item { Text("水平位置");Slider(editor.crop.x,{ change(editor.crop.copy(x=it)) },enabled=editing,valueRange=0f..1f) }
            item { Text("垂直位置");Slider(editor.crop.y,{ change(editor.crop.copy(y=it)) },enabled=editing,valueRange=0f..1f) }
            if(!authorized) item { TextButton(refresh,enabled=editing && !editor.loading) { Text("刷新权限") } }
            item { Button(save,enabled=editing && authorized && editor.maximumBytes!=null && !pending && ready,modifier=Modifier.fillMaxWidth()) { Text("使用这张群头像") } }
        }
        editor.feedback?.let { item { Text(it) } }
    }
}
