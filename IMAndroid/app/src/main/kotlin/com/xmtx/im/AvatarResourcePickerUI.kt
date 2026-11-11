package com.xmtx.im

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.delay

@Composable internal fun AvatarResourcePickerScreen(app: AppState,state: AvatarResourcePickerState,active: Boolean,
    search: (String)->Unit,next: ()->Unit,previous: ()->Unit,reload: ()->Unit,choose: (ResourceKey)->Unit,refreshProfile: ()->Unit,confirm: ()->Unit,dismiss: ()->Unit,visible: (PersistentList<ResourceKey>)->Unit={}) {
    val session=app.session as? SessionUi.SignedIn ?: return
    val resumed=LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val allowed=active && resumed && !session.demo && state.available && state.targetRoom !in app.snapshot.revokedRooms
    val grid=rememberLazyGridState()
    val interests by remember(grid,state.entries,allowed) { derivedStateOf {
        if(!allowed) persistentListOf() else grid.layoutInfo.visibleItemsInfo.filter { it.offset.y<grid.layoutInfo.viewportEndOffset && it.offset.y+it.size.height>grid.layoutInfo.viewportStartOffset }
            .mapNotNull { item -> state.entries.getOrNull(item.index)?.descriptor?.key }.distinct().take(12).toPersistentList()
    } }
    LaunchedEffect(interests) { visible(interests) }
    val context=LocalContext.current
    val group=state.targetRoom!=null
    val pending=if(group) app.snapshot.groupAvatarIntents.any { it.command.room==state.targetRoom && it.pending }
        else app.snapshot.profileIntents.any { !it.intent.locallyTerminal && it.work?.terminal!=true } || app.snapshot.ownProfileOperations.any { !it.terminal }
    val groupFresh by produceState(false,allowed,state.targetRoom,state.groupBaseline) {
        val baseline=state.groupBaseline
        value=allowed && baseline!=null && baseline.room==state.targetRoom && baseline.deadlineNanos-System.nanoTime()>0
        if(value) { delay(((requireNotNull(baseline).deadlineNanos-System.nanoTime()+999999)/1000000).coerceAtLeast(1));value=false }
    }
    val fresh=if(group) groupFresh else state.baseline?.let { it==app.snapshot.ownProfile && it.user==session.user && it.state==ProfileState.Active }==true
    var text by rememberSaveable(state.id) { mutableStateOf(state.search) }
    LaunchedEffect(text,state.available) { if(state.available) search(text) }
    LaunchedEffect(allowed) { if(!allowed) dismiss() }
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        if(group) Text("选择群头像",style=MaterialTheme.typography.titleMedium)
        OutlinedTextField(value=text,onValueChange={ if(it.toByteArray(Charsets.UTF_8).size<=255) text=it },label={ Text("搜索聊天图片") },
            enabled=allowed && !state.busy,modifier=Modifier.fillMaxWidth().testTag("avatar-resources-search"),singleLine=true)
        Text("支持 50 MB 以内的 JPEG 和 PNG，列表来自已同步的聊天图片。",style=MaterialTheme.typography.bodySmall)
        if(session.demo) Text("聊天图片选择需要登录真实账号。")
        if(state.loading || state.selecting) LinearProgressIndicator(Modifier.fillMaxWidth())
        if(state.indexing) Text("正在整理已同步的图片…",style=MaterialTheme.typography.bodySmall)
        if(pending) Text(if(group) "请先处理尚未确认的群头像修改。" else "请先处理尚未确认的资料修改。")
        state.feedback?.let { Text(it,color=MaterialTheme.colorScheme.error) }
        if(!state.loading && state.entries.isEmpty()) Text("本页暂无可选图片。")
        LazyVerticalGrid(state=grid,columns=GridCells.Adaptive(140.dp),modifier=Modifier.weight(1f).fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            items(state.entries,key={ "${it.descriptor.key.home}/${it.descriptor.key.media}" }) { entry ->
                val descriptor=entry.descriptor
                OutlinedCard(onClick={ choose(descriptor.key) },enabled=allowed && !state.busy && !pending,
                    modifier=Modifier.fillMaxWidth().testTag("avatar-resource-${descriptor.key.media}").semantics { contentDescription="选择头像图片：${descriptor.displayName}" }) {
                    Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        MessageImagePreview(state.previews[descriptor.key]?.takeIf { allowed && it.read.descriptor==descriptor })
                        Text(descriptor.displayName,maxLines=2,overflow=TextOverflow.Ellipsis)
                        Text(Formatter.formatShortFileSize(context,descriptor.byteCount),style=MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton(onClick=previous,enabled=allowed && !state.busy && !state.loading && state.pageNumber>1) { Text("上一页") }
            Text("第 ${state.pageNumber} 页")
            TextButton(onClick=next,enabled=allowed && !state.busy && !state.loading && state.next!=null) { Text("下一页") }
        }
        Row {
            TextButton(onClick=reload,enabled=allowed && !state.busy) { Text("刷新图片") }
            TextButton(onClick=refreshProfile,enabled=allowed && !state.busy && !state.loadingProfile) { Text(if(group) { if(state.loadingProfile) "正在读取权限…" else "刷新权限" } else if(state.loadingProfile) "正在读取资料…" else "刷新资料") }
        }
    }
    state.selected?.takeIf { allowed }?.let { selected ->
        AlertDialog(onDismissRequest=dismiss,title={ Text(if(group) "使用这张聊天图片作为群头像？" else "使用这张聊天图片作为头像？") },text={ Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(selected.descriptor.displayName)
            Text(if(group) "确认后复制这张图片并更新群头像，聊天中的原图保留。" else "确认后复制这张图片并更新头像，聊天中的原图保留。")
            if(pending) Text(if(group) "请先返回群头像页面，处理尚未确认的修改。" else "请先返回头像记录，处理尚未确认的资料修改。")
            if(!fresh) {
                Text(if(group) "请先刷新群管理权限。" else "请先刷新当前资料。")
                TextButton(onClick=refreshProfile,enabled=!state.busy && !state.loadingProfile) { Text(if(state.loadingProfile) "正在读取资料…" else "刷新后确认") }
            }
        } },confirmButton={ TextButton(onClick=confirm,enabled=allowed && !state.busy && !pending && fresh) { Text(if(state.submitting) "正在保存…" else "确认使用") } },
            dismissButton={ TextButton(onClick=dismiss,enabled=!state.submitting) { Text("取消") } })
    }
}
