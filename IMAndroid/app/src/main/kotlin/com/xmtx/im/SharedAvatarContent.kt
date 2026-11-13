package com.xmtx.im

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.sharedsdk.SharedAvatarAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable internal fun SharedAvatarImage(encoded: String?, tag: String) {
    val bitmap by produceState<Pair<String, androidx.compose.ui.graphics.ImageBitmap>?>(null, encoded) {
        value = if (encoded == null) null else withContext(Dispatchers.Default) {
            val data = Base64.decode(encoded, Base64.NO_WRAP)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth !in 1..4096 || bounds.outHeight !in 1..4096) null
            else BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = maxOf(1, maxOf(bounds.outWidth, bounds.outHeight) / 512) })?.asImageBitmap()?.let { encoded to it }
        }
    }
    if (encoded != null) bitmap?.takeIf { it.first == encoded }?.let { Image(it.second, contentDescription = "头像", modifier = Modifier.size(192.dp).testTag(tag)) }
}
private data class AvatarConfirmation(val revision: Long, val jpeg: String?)
@Composable internal fun SharedAvatarContent(state: SharedAppState, model: SharedAppViewModel, roomID: String?, back: () -> Unit) {
    val context = LocalContext.current
    val media = remember { SharedImageController(context.applicationContext) }
    val image by media.state.collectAsState()
    val editor = state.snapshot?.directory?.avatarEditor?.takeIf { it.roomID == roomID }
    val now = sharedDisplayTime()
    val valid = editor != null && editor.expiresAtElapsed > now
    var zoom by remember { mutableFloatStateOf(1f) }; var x by remember { mutableFloatStateOf(.5f) }; var y by remember { mutableFloatStateOf(.5f) }
    var confirm by remember { mutableStateOf<AvatarConfirmation?>(null) }
    var reapply by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> model.openAvatarEditor(roomID); uri?.let(media::load) }
    LaunchedEffect(roomID) { model.openAvatarEditor(roomID) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) { media.clear(); confirm = null; reapply = null }
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); media.close(); model.clearDiscovery() }
    }
    LazyColumn(Modifier.fillMaxSize().testTag("shared_avatar_editor"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Row { TextButton(back) { Text("返回") }; TextButton({ model.openAvatarEditor(roomID) }, enabled = !state.busy, modifier = Modifier.testTag("shared_avatar_refresh")) { Text("刷新头像") } } }
        item { Text(if (roomID == null) "我的头像" else "群头像", style = MaterialTheme.typography.headlineSmall)
            SharedAvatarImage(if (valid) editor?.image else null, "shared_avatar_current")
            if (!valid) Text("请刷新头像与操作权限")
            else if (editor?.canManage != true) Text("当前账号无权修改群头像")
        }
        if (valid && editor?.canManage == true) {
            item { Button({ picker.launch("image/*") }, enabled = !state.busy && !image.busy, modifier = Modifier.testTag("shared_avatar_pick")) { Text("选择图片") } }
            if (image.jpeg != null) item {
                SharedAvatarImage(image.jpeg, "shared_avatar_crop_preview")
                Text("缩放"); Slider(zoom, { zoom = it }, valueRange = 1f..3f, enabled = !image.busy, modifier = Modifier.testTag("shared_crop_zoom"))
                Text("水平位置"); Slider(x, { x = it }, enabled = !image.busy)
                Text("垂直位置"); Slider(y, { y = it }, enabled = !image.busy)
                Button({ media.crop(zoom, x, y) }, enabled = !image.busy, modifier = Modifier.testTag("shared_avatar_crop")) { Text("预览裁剪") }
                Button({ confirm = AvatarConfirmation(editor.revision, image.jpeg) }, enabled = !image.busy && !state.busy, modifier = Modifier.testTag("shared_avatar_upload")) { Text("上传此头像") }
            }
            if (editor.hasAvatar) item { TextButton({ confirm = AvatarConfirmation(editor.revision, null) }, enabled = !state.busy, modifier = Modifier.testTag("shared_avatar_remove")) { Text("移除头像") } }
        }
        image.error?.let { item { Text(it, color = MaterialTheme.colorScheme.error) } }
        if (editor?.failure != null) item { Text("头像服务暂不可用，请重新打开页面", color = MaterialTheme.colorScheme.error) }
        editor?.works?.forEach { work -> item(key = work.id) {
            Text(when (work.status) { "committed" -> "头像已更新，请刷新查看"; "preparing", "preparingAvatar", "waitingToSubmit" -> "正在准备上传"; "closed" -> "操作已关闭"; "cancelled" -> "已取消"; "needsDecision" -> "修订已变化或操作已过期，请选择后续处理"; "needsAttention" -> "需要确认结果"; else -> "正在确认更新" }, modifier = Modifier.testTag("shared_avatar_status"))
            if (work.retryable) TextButton({ model.avatarAction(roomID, work.id, SharedAvatarAction.Retry) }, enabled = !state.busy) { Text("重试原操作") }
            if (roomID != null && work.status in listOf("submitted", "needsAttention")) TextButton({ model.avatarAction(roomID, work.id, SharedAvatarAction.Query) }, enabled = !state.busy) { Text("查询结果") }
            if (roomID != null && work.status == "preparing") TextButton({ model.avatarAction(roomID, work.id, SharedAvatarAction.Cancel) }, enabled = !state.busy) { Text("取消上传") }
            if (roomID == null && work.status == "needsDecision") TextButton({ reapply = work.id }, enabled = !state.busy) { Text("按最新资料重新提交") }
            if (work.status in listOf("closed", "needsDecision")) TextButton({ model.avatarAction(roomID, work.id, SharedAvatarAction.Discard) }, enabled = !state.busy) { Text("放弃此操作") }
        } }
    }
    reapply?.let { id -> SharedConfirmation("按最新资料重新提交？", "将使用当前资料修订号重新应用此头像", { reapply = null }) { reapply = null; model.avatarAction(roomID, id, SharedAvatarAction.Reapply) } }
    confirm?.let { frozen -> SharedConfirmation(if (frozen.jpeg == null) "移除头像？" else "上传裁剪后的头像？", "将更新当前头像", { confirm = null }) {
        confirm = null; model.changeAvatar(roomID, frozen.revision, frozen.jpeg); media.clear()
    } }
}
