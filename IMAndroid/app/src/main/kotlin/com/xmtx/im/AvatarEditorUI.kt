package com.xmtx.im

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.xmtx.im.client.*
import com.xmtx.im.platform.NormalizedPhoto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.*

@Composable internal fun AvatarEditorScreen(state: AppState,editor: AvatarEditorState,active: Boolean,
    pick: ()->Unit,adjust: ()->Unit,refresh: ()->Unit,remove: ()->Unit,resume: (String)->Unit,discard: (String)->Unit,clearPhoto: ()->Unit,camera: ()->Unit={},avatar: AvatarPresentationBytes?=null,chatImages: ()->Unit={}) {
    val session=state.session as? SessionUi.SignedIn ?: return
    val resumed=LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val allowed=active && resumed && !session.demo
    val profile=state.snapshot.ownProfile?.takeIf { it.user==session.user }
    val fresh=editor.baseline?.takeIf { it==profile && it.state==ProfileState.Active }
    val tasks=state.snapshot.profileIntents.filter { it.intent.actor==session.user && (it.intent.upload!=null || it.intent.serverImport!=null || it.intent.avatar!=ProfileAvatarPatch.Unchanged) }
    val pending=state.snapshot.profileIntents.any { !it.intent.locallyTerminal && it.work?.terminal!=true } || state.snapshot.ownProfileOperations.any { !it.terminal }
    val busy=editor.operation!=null || editor.picking
    var removeConfirmation by remember { mutableStateOf(false) };var discardConfirmation by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(allowed) { if(!allowed) { removeConfirmation=false;discardConfirmation=null } }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
        item {
            Column(Modifier.fillMaxWidth(),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Avatar(profile?.identity?.displayName ?: "我",100,avatar.takeIf { allowed })
                Text(if(profile?.avatarMediaId!=null) "当前已设置头像" else "当前使用默认头像",style=MaterialTheme.typography.titleMedium)
                Text("相册与相机照片可调整显示范围，聊天图片将复制为新头像。",style=MaterialTheme.typography.bodyMedium)
            }
        }
        if(session.demo) item { Text("头像编辑需要登录真实账号。") }
        item { Button(onClick=pick,enabled=allowed && !busy && !pending && fresh!=null,modifier=Modifier.fillMaxWidth()) { Text("从相册选择") } }
        item { OutlinedButton(onClick=camera,enabled=allowed && !busy && !pending && fresh!=null,modifier=Modifier.fillMaxWidth()) { Text("拍照") } }
        item { OutlinedButton(onClick=chatImages,enabled=allowed && !busy && !pending && fresh!=null,modifier=Modifier.fillMaxWidth()) { Text("从聊天图片选择") } }
        if(editor.picking) item { Text(if(editor.source==AvatarPhotoSource.Camera) "请在系统相机中拍摄照片" else "请在系统选择器中选择一张照片") }
        if(editor.operation!=null) item { Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp)
            Text(when(editor.operation) { AvatarEditorOperation.PreparingCamera->"正在准备相机…";AvatarEditorOperation.Reading->"正在读取照片…";AvatarEditorOperation.Saving->"正在保存头像修改…";else->"正在更新任务…" })
        } }
        editor.photo?.let { photo -> item {
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text("待保存图片",style=MaterialTheme.typography.titleMedium)
                AvatarPhotoCanvas(photo,editor.crop,Modifier.size(140.dp))
                Row { TextButton(onClick=adjust,enabled=allowed && !busy) { Text("继续调整") };TextButton(onClick=clearPhoto,enabled=allowed && !busy) { Text("取消选图") } }
            } }
        } }
        if(!session.demo && fresh==null) item { Text(if(editor.loadingProfile) "正在读取当前资料…" else "刷新当前资料后可编辑头像。") }
        if(pending) item { Text("前一笔资料修改尚未确认，请先处理下方记录。") }
        item { Row {
            TextButton(onClick=refresh,enabled=allowed && !busy && !editor.loadingProfile) { Text("刷新资料") }
            if(profile?.avatarMediaId!=null) TextButton(onClick={ removeConfirmation=true },enabled=allowed && !busy && !pending && fresh!=null) { Text("移除头像") }
        } }
        editor.feedback?.let { item { Text(it) } }
        state.error?.let { item { Text(it,color=MaterialTheme.colorScheme.error) } }
        if(tasks.isNotEmpty()) item { Text("头像修改记录",style=MaterialTheme.typography.titleLarge) }
        items(tasks.reversed(),key={ it.intent.id }) { status ->
            Card(Modifier.fillMaxWidth().testTag("avatar-task-${status.intent.id}")) { Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(if(status.intent.avatar==ProfileAvatarPatch.Remove) "移除头像" else "更换头像",style=MaterialTheme.typography.titleMedium)
                Text(when(status.phase) {
                    ProfileIntentPhase.WaitingToSubmit->"等待保存资料"
                    ProfileIntentPhase.PreparingAvatar->"正在准备头像"
                    ProfileIntentPhase.Confirming->"正在确认修改结果"
                    ProfileIntentPhase.Committed->"头像修改已确认"
                    ProfileIntentPhase.Closed->"这次修改已关闭"
                    ProfileIntentPhase.NeedsAttention->if(status.canReplace) "这次修改未完成，可按最新资料重新保存" else "需要继续处理这次修改"
                })
                if(status.phase==ProfileIntentPhase.Committed) Text("这是原修改的结果；当前资料可能已由其他设备更新。",style=MaterialTheme.typography.bodySmall)
                if(status.sourceRetained && status.phase!=ProfileIntentPhase.Committed) {
                    if(status.phase==ProfileIntentPhase.NeedsAttention || status.canReplace) TextButton(onClick={ resume(status.intent.id) },enabled=allowed && !busy) {
                        Text(if(status.canReplace) "按最新资料重新保存" else "继续处理")
                    }
                    if(status.work?.terminal!=false) TextButton(onClick={ discardConfirmation=status.intent.id },enabled=allowed && !busy) { Text("放弃这次修改") }
                    if(status.intent.upload!=null) Text("原图已保留，可继续恢复。",style=MaterialTheme.typography.bodySmall)
                    if(status.intent.serverImport!=null) Text("导入任务已保留，可继续恢复。",style=MaterialTheme.typography.bodySmall)
                }
            } }
        }
    }
    if(removeConfirmation) AlertDialog(onDismissRequest={ removeConfirmation=false },title={ Text("移除当前头像？") },text={ Text("确认后将使用默认头像。") },
        confirmButton={ TextButton(onClick={ removeConfirmation=false;remove() },enabled=allowed && fresh!=null && !busy) { Text("确认移除") } },dismissButton={ TextButton(onClick={ removeConfirmation=false }) { Text("取消") } })
    discardConfirmation?.let { id -> AlertDialog(onDismissRequest={ discardConfirmation=null },title={ Text("放弃这次头像修改？") },text={ Text(if(tasks.firstOrNull { it.intent.id==id }?.intent?.serverImport!=null) "将放弃这次头像修改，并停止使用这份导入结果。" else "尚未完成的上传将取消，原图不再为这次修改保留。") },
        confirmButton={ TextButton(onClick={ discardConfirmation=null;discard(id) },enabled=allowed && !busy) { Text("确认放弃") } },dismissButton={ TextButton(onClick={ discardConfirmation=null }) { Text("取消") } }) }
}

@Composable internal fun AvatarCropScreen(state: AppState,editor: AvatarEditorState,active: Boolean,change: (AvatarCrop)->Unit,save: ()->Unit,refresh: ()->Unit) {
    val session=state.session as? SessionUi.SignedIn ?: return
    val resumed=LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val enabled=active && resumed && !session.demo && editor.operation==null
    val photo=editor.photo
    val fresh=editor.baseline?.takeIf { it==state.snapshot.ownProfile && it.state==ProfileState.Active }
    val pending=state.snapshot.profileIntents.any { !it.intent.locallyTerminal && it.work?.terminal!=true } || state.snapshot.ownProfileOperations.any { !it.terminal }
    var previewReady by remember(photo) { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp),horizontalAlignment=Alignment.CenterHorizontally) {
        item { Text("移动和缩放照片，调整头像显示范围。") }
        if(photo==null) item { Text("请返回选择一张照片；尚未保存的图片不会跨应用重启保留。") }
        else {
            item { AvatarPhotoCanvas(photo,editor.crop,Modifier.widthIn(max=420.dp).fillMaxWidth().aspectRatio(1f),if(enabled) change else null) { previewReady=it } }
            item { Text("缩放");Slider(editor.crop.zoom,{ change(editor.crop.copy(zoom=it)) },enabled=enabled,valueRange=1f..5f,modifier=Modifier.testTag("avatar-crop-zoom").semantics { contentDescription="头像缩放" }) }
            item { Text("水平位置");Slider(editor.crop.x,{ change(editor.crop.copy(x=it)) },enabled=enabled,valueRange=0f..1f,modifier=Modifier.testTag("avatar-crop-x").semantics { contentDescription="头像水平位置" }) }
            item { Text("垂直位置");Slider(editor.crop.y,{ change(editor.crop.copy(y=it)) },enabled=enabled,valueRange=0f..1f,modifier=Modifier.testTag("avatar-crop-y").semantics { contentDescription="头像垂直位置" }) }
            item { TextButton(onClick={ change(AvatarCrop()) },enabled=enabled) { Text("重置位置") } }
            if(fresh==null) item { Text("刷新当前资料后可保存。");TextButton(onClick=refresh,enabled=enabled && !editor.loadingProfile) { Text("刷新资料") } }
            item { Button(onClick=save,enabled=enabled && fresh!=null && !pending && previewReady,modifier=Modifier.fillMaxWidth()) { Text(if(editor.operation==AvatarEditorOperation.Saving) "正在保存…" else "使用这张头像") } }
        }
        editor.feedback?.let { item { Text(it,color=MaterialTheme.colorScheme.error) } }
    }
}

/** Rendering-only bitmap lifetime. Application snapshots contain only the immutable encoded photo. */
@Composable internal fun AvatarPhotoCanvas(photo: NormalizedPhoto,crop: AvatarCrop,modifier: Modifier,
    change: ((AvatarCrop)->Unit)?=null,ready: (Boolean)->Unit={}) {
    val preview by produceState<ImageBitmap?>(null,photo) {
        value=withContext(Dispatchers.Default) { photo.data.newInput().use { BitmapFactory.decodeStream(it)?.asImageBitmap() } }
    }
    val notify by rememberUpdatedState(ready)
    LaunchedEffect(preview) { notify(preview!=null) }
    var pixels by remember { mutableIntStateOf(1) };val currentCrop by rememberUpdatedState(crop);val onChange by rememberUpdatedState(change)
    val gestures=if(change==null) Modifier else Modifier.pointerInput(photo) {
        detectTransformGestures { _,pan,zoom,_ ->
            if(zoom.isFinite() && zoom>0) {
                val old=currentCrop;val nextZoom=(old.zoom*zoom).coerceIn(1f,5f)
                val side=min(photo.dimensions.width,photo.dimensions.height)/nextZoom
                onChange?.invoke(AvatarCrop(nextZoom,(old.x-pan.x/pixels*side/photo.dimensions.width).coerceIn(0f,1f),
                    (old.y-pan.y/pixels*side/photo.dimensions.height).coerceIn(0f,1f)).constrained(photo.dimensions))
            }
        }
    }
    Box(modifier.background(Color.White).onSizeChanged { pixels=it.width.coerceAtLeast(1) }.then(gestures).semantics { contentDescription="头像裁剪区域" }) {
        val image=preview
        if(image==null) CircularProgressIndicator(Modifier.align(Alignment.Center))
        else Canvas(Modifier.fillMaxSize()) {
            val rect=crop.rect(photo.dimensions)
            val x=floor(rect.x*image.width).toInt().coerceIn(0,image.width-1);val y=floor(rect.y*image.height).toInt().coerceIn(0,image.height-1)
            val side=min(ceil((rect.x+rect.width)*image.width).toInt()-x,ceil((rect.y+rect.height)*image.height).toInt()-y).coerceIn(1,min(image.width-x,image.height-y))
            drawImage(image,srcOffset=IntOffset(x,y),srcSize=IntSize(side,side),dstSize=IntSize(size.width.toInt().coerceAtLeast(1),size.height.toInt().coerceAtLeast(1)),filterQuality=FilterQuality.High)
            val mask=Path().apply { fillType=PathFillType.EvenOdd;addRect(androidx.compose.ui.geometry.Rect(0f,0f,size.width,size.height));addOval(androidx.compose.ui.geometry.Rect(0f,0f,size.width,size.height)) }
            drawPath(mask,Color.Black.copy(alpha=0.5f));drawCircle(Color.White,radius=size.minDimension/2-1.dp.toPx(),style=Stroke(1.dp.toPx()))
        }
    }
}
