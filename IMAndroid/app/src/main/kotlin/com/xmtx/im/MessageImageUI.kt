package com.xmtx.im

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.persistentSetOf

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun MessageImageScreen(app: AppState,state: MessageImageState?,selection: MessageImageSelection,active: Boolean,retry: ()->Unit,original: ()->Unit,openSources: (RoomId)->MessageSourceSession?={null}) {
    val foreground=rememberReadForeground()
    val sources=rememberMessageSources(selection.location.room,persistentSetOf(selection.location.message),app,active,openSources)
    val message=sources.state.messages[selection.location.message]
    val descriptor=message?.takeUnless { it.withdrawn || it.redacted }?.media?.presentations?.firstOrNull { it.media==selection.media }?.descriptor
    val allowed=active && foreground && state?.selection==selection && state.available && selection.location.room !in app.snapshot.revokedRooms && descriptor!=null
    val frame=state?.takeIf { it.selection==selection }?.frame?.takeIf { allowed && it.valid() && it.read.matchesMessage(message,descriptor) }
    val decoded by produceState<Pair<MessageImageFrame,ImageBitmap>?>(null,frame) {
        value=null
        if(frame!=null) {
            val bitmap=decodeImageFrame(frame)
            if(bitmap!=null && frame.valid()) value=frame to bitmap
            awaitPresentationExpiry(frame.deadlineNanos);value=null
        }
    }
    val shown=decoded?.takeIf { it.first===frame && frame?.valid()==true }?.second
    var scale by remember(frame) { mutableFloatStateOf(1f) };var pan by remember(frame) { mutableStateOf(Offset.Zero) };var size by remember { mutableStateOf(IntSize.Zero) }
    fun zoom(next: Float,delta: Offset=Offset.Zero) {
        scale=next.coerceIn(1f,8f)
        val x=size.width*(scale-1)/2;val y=size.height*(scale-1)/2
        pan=Offset((pan.x+delta.x).coerceIn(-x,x),(pan.y+delta.y).coerceIn(-y,y))
    }
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text(descriptor?.displayName ?: "聊天图片",style=MaterialTheme.typography.titleMedium,maxLines=2)
        sources.state.feedback?.let {Text(it);TextButton(onClick=sources.retry) {Text("重试读取消息")}}
        if(sources.state.loading || state?.loading==true || state?.originalLoading==true) LinearProgressIndicator(Modifier.fillMaxWidth())
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { size=it }.testTag("message-image-canvas").clipToBounds()
            .pointerInput(frame,shown) { detectTapGestures(onDoubleTap={ if(shown!=null) zoom(if(scale>1f) 1f else 2f) }) }
            .transformable(rememberTransformableState { change,delta,_->if(shown!=null) zoom(scale*change,delta) }),contentAlignment=Alignment.Center) {
            if(shown!=null) Image(shown,"聊天图片",Modifier.fillMaxSize().graphicsLayer { scaleX=scale;scaleY=scale;translationX=pan.x;translationY=pan.y }.testTag("message-image-pixels"),contentScale=ContentScale.Fit)
            else Text(if(!allowed) "图片当前不可查看" else if(state?.loading==true) "正在加载预览" else "尚未显示图片",Modifier.testTag("message-image-placeholder"))
        }
        state?.takeIf { it.selection==selection }?.feedback?.let { Text(it,style=MaterialTheme.typography.bodySmall) }
        if(shown!=null) {
            Text(if(frame?.original==true) "原图已读取 · 适配屏幕显示" else "图片预览",style=MaterialTheme.typography.labelMedium)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick={ zoom(scale/2) },enabled=scale>1f) { Text("缩小") }
                OutlinedButton(onClick={ zoom(scale*2) },enabled=scale<8f) { Text("放大") }
                TextButton(onClick={ zoom(1f) }) { Text("重置") }
            }
        }
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick=retry,enabled=allowed && state?.loading!=true && state?.originalLoading!=true) { Text("重新加载") }
            Button(onClick=original,enabled=allowed && state?.originalLoading!=true && frame?.original!=true) { Text(if(state?.originalLoading==true) "正在读取原图" else "查看原图") }
        }
    }
}
private suspend fun decodeImageFrame(frame: MessageImageFrame): ImageBitmap? {
    var bitmap: Bitmap?=null
    try {
        withContext(Dispatchers.Default) {
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
            frame.encoded.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
            val maximum=if(frame.original) 2048 else 1280
            if(bounds.outWidth !in 1..maximum || bounds.outHeight !in 1..maximum) return@withContext
            currentCoroutineContext().ensureActive()
            bitmap=frame.encoded.newInput().use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inPreferredConfig=Bitmap.Config.ARGB_8888 }) }
        }
        currentCoroutineContext().ensureActive();if(!frame.valid()) { bitmap?.recycle();return null };return bitmap?.asImageBitmap()
    } catch(error: CancellationException) { bitmap?.recycle();throw error }
    catch(_: Exception) { bitmap?.recycle();return null }
}
