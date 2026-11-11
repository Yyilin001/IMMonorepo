package com.xmtx.im

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Audiotrack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.compose.ContentFrame
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentSetOf

@androidx.annotation.OptIn(UnstableApi::class)
@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun MessagePlaybackScreen(app: AppState,state: MessagePlaybackState?,selection: MessagePlaybackSelection,active: Boolean,
    runtime: (String)->Player?,toggle: ()->Unit,seek: (Long)->Unit,retry: ()->Unit,files: ()->Unit,openSources: (RoomId)->MessageSourceSession?={null}) {
    val foreground=rememberReadForeground()
    val sources=rememberMessageSources(selection.location.room,persistentSetOf(selection.location.message),app,active,openSources)
    val message=sources.state.messages[selection.location.message]
    val descriptor=message?.takeUnless {it.withdrawn || it.redacted || it.delivery!=Delivery.Accepted}?.media?.presentations?.firstOrNull {it.media==selection.media}?.descriptor
    val value=state?.takeIf {it.selection==selection}
    val visible=active && foreground && selection.location.room !in app.snapshot.revokedRooms && descriptor!=null
    val allowed=visible && value?.available==true && value.read?.matchesMessage(message,descriptor)==true
    val permitted=allowed && value?.deadlineNanos?.let {it-System.nanoTime()>0}==true
    val player=if(permitted) runtime(value!!.owner) else null
    val video=descriptor?.contentType?.startsWith("video/")==true
    val view=LocalView.current
    DisposableEffect(view,video,permitted,value?.playing) {
        view.keepScreenOn=video && permitted && value?.playing==true
        onDispose {view.keepScreenOn=false}
    }
    var dragging by remember(value?.owner,value?.read) {mutableStateOf<Float?>(null)}
    val duration=value?.durationMs ?: 0;val position=value?.positionMs ?: 0
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
        Text(descriptor?.displayName ?: "音视频附件",style=MaterialTheme.typography.titleMedium,maxLines=2)
        sources.state.feedback?.let {Text(it);TextButton(onClick=sources.retry) {Text("重试读取消息")}}
        if(sources.state.loading || value?.loading==true || value?.buffering==true) LinearProgressIndicator(Modifier.fillMaxWidth())
        Box(Modifier.fillMaxWidth().weight(1f).testTag("message-playback-canvas"),contentAlignment=Alignment.Center) {
            if(video && player!=null) ContentFrame(player,Modifier.fillMaxSize().background(Color.Black).testTag("message-playback-video"),contentScale=ContentScale.Fit,keepContentOnReset=false)
            else if(!video && allowed) Icon(Icons.Outlined.Audiotrack,"音频",Modifier.size(80.dp))
            else Text(if(!allowed) "音视频当前不可播放" else if(value?.loading==true) "正在读取原件…" else "尚未显示视频")
        }
        value?.feedback?.let {Text(it,Modifier.testTag("message-playback-feedback"),style=MaterialTheme.typography.bodySmall)}
        Text("${playbackTime(position)} / ${playbackTime(duration)}",Modifier.testTag("message-playback-time"),style=MaterialTheme.typography.labelLarge)
        Slider(value=dragging ?: (if(duration>0) position.toFloat()/duration else 0f).coerceIn(0f,1f),onValueChange={dragging=it},onValueChangeFinished={dragging?.let {seek((it*duration).toLong())};dragging=null},
            enabled=permitted && value?.ready==true && value.seekable && duration>0,modifier=Modifier.testTag("message-playback-seek").semantics {contentDescription="播放进度"})
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            OutlinedButton({seek((position-10000).coerceAtLeast(0))},enabled=permitted && value?.ready==true && value.seekable) {Text("后退 10 秒")}
            Button(toggle,enabled=permitted && (value?.ready==true || value?.buffering==true),modifier=Modifier.testTag("message-playback-toggle")) {Text(if(value?.playRequested==true) "暂停" else if(value?.ended==true) "重播" else "播放")}
            OutlinedButton({seek((position+10000).coerceAtMost(duration))},enabled=permitted && value?.ready==true && value.seekable) {Text("前进 10 秒")}
        }
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(retry,enabled=active && foreground && value?.loading!=true) {Text("重新加载")}
            TextButton(files,enabled=visible) {Text("文件操作")}
        }
    }
}
internal fun playbackTime(milliseconds: Long): String {
    val seconds=milliseconds.coerceAtLeast(0)/1000
    return if(seconds>=3600) "%d:%02d:%02d".format(java.util.Locale.ROOT,seconds/3600,seconds/60%60,seconds%60) else "%d:%02d".format(java.util.Locale.ROOT,seconds/60,seconds%60)
}
