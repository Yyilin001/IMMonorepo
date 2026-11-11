package com.xmtx.im

import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.xmtx.im.platform.NormalizedPhoto

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun DraftImageScreen(state: DraftImageState?,selection: DraftImageSelection,active: Boolean,retry: ()->Unit) {
    val foreground=rememberReadForeground()
    val current=state?.takeIf { it.selection==selection }
    val allowed=active && foreground && current?.available==true
    val photo=current?.photo?.takeIf { allowed && current.attachment?.asset==selection.asset }
    val decoded by produceState<Pair<NormalizedPhoto,ImageBitmap>?>(null,photo) {
        value=null
        if(photo!=null) decodeLocalPhoto(photo,2048,20*1024*1024)?.let { value=photo to it }
    }
    val shown=decoded?.takeIf { it.first===photo }?.second
    var scale by remember(photo) { mutableFloatStateOf(1f) };var pan by remember(photo) { mutableStateOf(Offset.Zero) };var size by remember { mutableStateOf(IntSize.Zero) }
    fun zoom(next: Float,delta: Offset=Offset.Zero) {
        scale=next.coerceIn(1f,8f);val x=size.width*(scale-1)/2;val y=size.height*(scale-1)/2
        pan=Offset((pan.x+delta.x).coerceIn(-x,x),(pan.y+delta.y).coerceIn(-y,y))
    }
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text(current?.attachment?.displayName ?: "草稿图片",style=MaterialTheme.typography.titleMedium,maxLines=2)
        if(current?.loading==true) LinearProgressIndicator(Modifier.fillMaxWidth())
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { size=it }.clipToBounds().testTag("draft-image-canvas")
            .pointerInput(photo,shown) { detectTapGestures(onDoubleTap={ if(shown!=null) zoom(if(scale>1f) 1f else 2f) }) }
            .transformable(rememberTransformableState { change,delta,_->if(shown!=null) zoom(scale*change,delta) }),contentAlignment=Alignment.Center) {
            if(shown!=null) Image(shown,"草稿图片",Modifier.fillMaxSize().graphicsLayer { scaleX=scale;scaleY=scale;translationX=pan.x;translationY=pan.y }.testTag("draft-image-pixels"),contentScale=ContentScale.Fit)
            else Text(if(!allowed) "图片当前不可查看" else if(current?.loading==true) "正在读取本地图片" else "尚未显示图片",Modifier.testTag("draft-image-placeholder"))
        }
        current?.feedback?.let { Text(it,style=MaterialTheme.typography.bodySmall) }
        if(shown!=null) {
            Text("本地草稿图片 · 适配屏幕显示",style=MaterialTheme.typography.labelMedium)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick={ zoom(scale/2) },enabled=scale>1f) { Text("缩小") }
                OutlinedButton(onClick={ zoom(scale*2) },enabled=scale<8f) { Text("放大") }
                TextButton(onClick={ zoom(1f) }) { Text("重置") }
            }
        }
        OutlinedButton(onClick=retry,enabled=allowed && current?.loading!=true) { Text("重新加载") }
    }
}
