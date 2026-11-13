package com.xmtx.im

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.xmtx.im.sharedsdk.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/** Device image conversion / document I/O. No resource protocol, retries or business state. */
internal object SharedDocumentIO {
    suspend fun import(context: android.content.Context, client: SharedClient, room: String, uri: Uri, image: Boolean): SharedSnapshot = withContext(Dispatchers.IO) {
        if (image) {
            val bitmap = SharedImageTools.read(context, uri)
            try {
                val bytes = ByteArrayOutputStream().also { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it)) }.toByteArray()
                ByteArrayInputStream(bytes).use { client.importAttachment(room, "image.jpg", "image/jpeg", it, bitmap.width, bitmap.height) }
            } finally { bitmap.recycle() }
        } else {
            val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "file.bin"
            val type = context.contentResolver.getType(uri) ?: "application/octet-stream"
            checkNotNull(context.contentResolver.openInputStream(uri)).use { client.importAttachment(room, name, type, it) }
        }
    }
    suspend fun export(context: android.content.Context, client: SharedClient, room: String, message: String, media: String, uri: Uri): SharedSnapshot = withContext(Dispatchers.IO) {
        var complete = false
        try {
            client.openResource(room, message, media)
            val result = checkNotNull(context.contentResolver.openOutputStream(uri, "wt")).use { client.exportResource(it) }
            complete = true; result
        } finally {
            if (!complete) runCatching { android.provider.DocumentsContract.deleteDocument(context.contentResolver, uri) }
        }
    }
}
@Composable internal fun SharedAttachmentComposer(state: SharedAppState, room: String, model: SharedAppViewModel, text: String, sent: () -> Unit) {
    val generation by rememberUpdatedState(state.generation)
    var pickedGeneration by remember { mutableStateOf<Long?>(null) }
    val image = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> if (pickedGeneration == generation && uri != null) model.importAttachment(room, uri, true); pickedGeneration = null }
    val file = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> if (pickedGeneration == generation && uri != null) model.importAttachment(room, uri, false); pickedGeneration = null }
    Column {
        Row {
            TextButton({ pickedGeneration = generation; image.launch("image/*") }, enabled = !state.busy, modifier = Modifier.testTag("shared_attach_image")) { Text("图片") }
            TextButton({ pickedGeneration = generation; file.launch("*/*") }, enabled = !state.busy, modifier = Modifier.testTag("shared_attach_file")) { Text("文件（最多 32 MiB）") }
        }
        state.snapshot?.resource?.draft?.let { draft ->
            Text("${draft.name} · ${draft.bytes} 字节", modifier = Modifier.testTag("shared_attachment_draft"))
            Row {
                Button({ model.sendAttachment(room, draft.id, text, sent) }, enabled = !state.busy, modifier = Modifier.testTag("shared_send_attachment")) { Text("发送附件") }
                TextButton(model::clearResources, enabled = !state.busy) { Text("移除附件") }
            }
        }
    }
}
@Composable internal fun SharedResourceContent(state: SharedAppState, room: String, message: String, media: String, model: SharedAppViewModel, back: () -> Unit, transfers: () -> Unit) {
    val current = state.snapshot?.resource?.takeIf { it.roomID == room && it.messageID == message && it.selected?.id == media }
    var feedback by remember { mutableStateOf<String?>(null) }
    val generation by rememberUpdatedState(state.generation); var exportGeneration by remember { mutableStateOf<Long?>(null) }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(current?.selected?.contentType ?: "application/octet-stream")) { uri ->
        if (exportGeneration == generation && uri != null) model.exportResource(room, message, media, uri) { feedback = "已保存到所选位置" }; exportGeneration = null
    }
    LaunchedEffect(room, message, media) { model.openResource(room, message, media) }
    DisposableEffect(Unit) { onDispose { model.clearResources() } }
    val now = sharedDisplayTime()
    LazyColumn(Modifier.fillMaxSize().testTag("shared_resource_detail"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { TextButton(back) { Text("返回") }; Text("附件", style = MaterialTheme.typography.titleLarge) }
        item { TextButton({ model.openResource(room,message,media) }, enabled = !state.busy, modifier = Modifier.testTag("shared_resource_refresh")) { Text("刷新附件权限") } }
        current?.selected?.let { attachment ->
            item { Text(attachment.name); Text("${attachment.contentType} · ${attachment.bytes} 字节") }
            if (attachment.kind in listOf("image", "animated_image")) item {
                SharedAvatarImage(if (current.expiresAtElapsed > now) current.image else null, "shared_resource_image")
                Button(model::previewResource, enabled = !state.busy, modifier = Modifier.testTag("shared_resource_preview")) { Text("查看图片") }
            }
            item { Button(model::downloadResource, enabled = !state.busy && attachment.bytes <= 33_554_432, modifier = Modifier.testTag("shared_resource_download")) { Text("下载原文件") }
                Text("下载完成后可保存。保存文件会复制到你选择的位置。")
                Button({ exportGeneration = generation; feedback = null; save.launch(attachment.name) }, enabled = !state.busy && attachment.bytes <= 33_554_432, modifier = Modifier.testTag("shared_resource_save")) { Text("保存到设备") }
                if (attachment.bytes > 33_554_432) Text("当前支持下载最多 32 MiB 的文件")
            }
        }
        item { TextButton(transfers, modifier = Modifier.testTag("shared_resource_transfers")) { Text("上传与下载任务") }; feedback?.let { Text(it, modifier = Modifier.testTag("shared_resource_saved")) } }
    }
}
@Composable internal fun SharedTransfersContent(state: SharedAppState, model: SharedAppViewModel, back: () -> Unit) {
    LazyColumn(Modifier.fillMaxSize().testTag("shared_transfers"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { TextButton(back) { Text("返回") }; Text("上传与下载", style = MaterialTheme.typography.titleLarge); Text("显示最近 50 个任务") }
        items(state.snapshot?.resource?.transfers ?: kotlinx.collections.immutable.persistentListOf(), key = { it.kind + it.id }) { transfer ->
            Column(Modifier.testTag("shared_transfer_${transfer.id}")) {
                Text(transfer.name)
                Text(when (transfer.phase) { "completed" -> "已完成"; "cancelled" -> "已取消"; "paused" -> "已暂停"; "failed", "requiresAttention" -> "需要处理"; "waitingRetry" -> "等待重试"; "queued" -> "已排队"; "transferring" -> "传输中"; "verifying" -> "正在校验"; "processing" -> "服务端处理中"; else -> "正在确认状态" })
                transfer.bytes?.let { total -> Text("已确认 ${transfer.confirmed ?: 0} / $total 字节") }
                Row {
                    SharedTransferAction.entries.filter { it.wire in transfer.actions }.forEach { action ->
                        TextButton({ model.transferAction(transfer.id, action) }, enabled = !state.busy) { Text(when (action) { SharedTransferAction.Pause -> "暂停"; SharedTransferAction.Resume -> "继续"; SharedTransferAction.Cancel -> "取消下载"; else -> "重试" }) }
                    }
                }
            }
        }
        state.snapshot?.resource?.failure?.let { item { Text("资源服务暂不可用，请重新登录后重试") } }
    }
}
