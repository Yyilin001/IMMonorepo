package dev.local.ripple

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.util.Size
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.*
import java.io.File

private fun decode(path: String, edge: Int): Bitmap =
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(File(path))) { decoder, info, _ ->
        val (w, h) = info.size.let { it.width to it.height }
        val scale = minOf(1f, edge.toFloat() / maxOf(w, h))
        decoder.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
    }

@Composable fun Picture(file: String?, ratio: Float, mine: Boolean, modifier: Modifier, large: Boolean = false) {
    val bitmap by produceState<Bitmap?>(null, file, large) {
        if (file != null) value = withContext(Dispatchers.IO) { runCatching { decode(file, if (large) 2048 else 540) }.getOrNull() }
    }
    val value = bitmap
    Box(modifier.aspectRatio(ratio.coerceIn(.35f, 3f)).background(if (mine) Color(0xFFD5E7DC) else Color(0xFFDCE7ED)), Alignment.Center) {
        if (value != null) Image(value.asImageBitmap(), "图片消息", Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        else Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Rounded.Landscape, "图片消息", Modifier.size(if (large) 80.dp else 46.dp), tint = Muted)
            Label(if (file == null) "模拟图片" else "图片", 12, Muted)
        }
    }
}

@Composable fun Gallery(pictures: PersistentList<Message>, start: Int, close: () -> Unit) {
    if (pictures.isEmpty()) return
    val pages = rememberPagerState(start.coerceIn(pictures.indices)) { pictures.size }
    val scope = rememberCoroutineScope()
    var zoom by remember(pages.currentPage) { mutableFloatStateOf(1f) }
    var pan by remember(pages.currentPage) { mutableStateOf(Offset.Zero) }
    var pull by remember(pages.currentPage) { mutableFloatStateOf(0f) }
    Dialog(close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(close) { Icon(Icons.Rounded.Close, "关闭图片预览", tint = White) }
                Label(if (pictures.size == 1) "图片" else "${pages.currentPage + 1} / ${pictures.size}", 17, White)
            }
            HorizontalPager(pages, Modifier.weight(1f), userScrollEnabled = zoom == 1f) { index ->
                val m = pictures[index]
                val transform = rememberTransformableState { delta, move, _ ->
                    zoom = (zoom * delta).coerceIn(1f, 4f)
                    pan = if (zoom == 1f) Offset.Zero else pan + move
                }
                Box(Modifier.fillMaxSize().pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = { zoom = if (zoom == 1f) 2f else 1f; pan = Offset.Zero })
                }.pointerInput(zoom == 1f) {
                    if (zoom == 1f) detectVerticalDragGestures(
                        onDragEnd = { if (kotlin.math.abs(pull) > 88.dp.toPx()) close(); pull = 0f },
                        onDragCancel = { pull = 0f }
                    ) { change, delta -> change.consume(); pull += delta }
                }.transformable(transform, canPan = { zoom > 1f }), Alignment.Center) {
                    Picture(m.file, m.ratio, m.sender == null, Modifier.fillMaxWidth().graphicsLayer {
                        scaleX = zoom; scaleY = zoom; translationX = pan.x; translationY = pan.y + pull
                    }, large = true)
                }
            }
            if (pictures.size > 1) Row(Modifier.align(Alignment.CenterHorizontally)) {
                IconButton({ scope.launch { pages.animateScrollToPage(pages.currentPage - 1) } }, enabled = pages.currentPage > 0) {
                    Icon(Icons.Rounded.ChevronLeft, "上一张", tint = White)
                }
                IconButton({ scope.launch { pages.animateScrollToPage(pages.currentPage + 1) } }, enabled = pages.currentPage < pictures.lastIndex) {
                    Icon(Icons.Rounded.ChevronRight, "下一张", tint = White)
                }
            }
        }
    }
}

// Messages are process-local. Keep the current run's originals outside the reclaimable thumbnail cache.
private object PhotoFiles {
    private var directory: File? = null

    @Synchronized fun save(ctx: Context, staged: File): File {
        val folder = directory ?: File(ctx.filesDir, "photos").also {
            if (it.exists() && !it.deleteRecursively()) throw java.io.IOException("Cannot retire previous photos")
            if (!it.mkdirs()) throw java.io.IOException("Cannot create photo directory")
            directory = it
        }
        val dest = File(folder, staged.name)
        if (!staged.renameTo(dest)) {
            try { staged.copyTo(dest) } catch (e: java.io.IOException) { dest.delete(); throw e }
            staged.delete()
        }
        return dest
    }
}

private fun tempPhoto(ctx: Context) = File.createTempFile("photo-", ".img", File(ctx.cacheDir, "camera").apply { mkdirs() })

@Composable fun AttachmentPicker(store: ImStore, id: Int, recipient: String, expanded: Boolean, sent: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by rememberSaveable { mutableStateOf<String?>(null) }
    var camera by rememberSaveable { mutableStateOf<String?>(null) }
    var ratio by rememberSaveable { mutableFloatStateOf(1f) }
    var busy by remember { mutableStateOf(false) }
    fun error(message: String) = Toast.makeText(ctx, message, Toast.LENGTH_SHORT).show()
    fun prepare(uri: Uri?, capture: String?) {
        if (uri == null && capture == null) return
        busy = true
        scope.launch {
            var file: File? = null
            try {
                val dimensions = withContext(Dispatchers.IO) {
                    val target = capture?.let(::File) ?: tempPhoto(ctx)
                    file = target
                    if (uri != null) ctx.contentResolver.openInputStream(uri)!!.use { input ->
                        target.outputStream().use { input.copyTo(it) }
                    }
                    val thumbnail = decode(target.absolutePath, 256)
                    Size(thumbnail.width, thumbnail.height).also { thumbnail.recycle() }
                }
                ratio = dimensions.width.toFloat() / dimensions.height
                pending = file!!.absolutePath
            } catch (e: Exception) {
                file?.delete()
                if (e is CancellationException) throw e
                error("无法读取这张图片，请重试。")
            } finally { busy = false }
        }
    }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { prepare(it, null) }
    val take = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val path = camera
        camera = null
        if (ok) prepare(null, path) else path?.let { File(it).delete() }
    }
    if (expanded) Row(Modifier.fillMaxWidth().background(Mist).padding(15.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedButton({ runCatching { pick.launch("image/*") }.onFailure { error("无法打开相册。") } }, enabled = !busy) {
            Icon(Icons.Rounded.PhotoLibrary, null); Text("相册")
        }
        OutlinedButton({
            runCatching {
                val file = tempPhoto(ctx)
                camera = file.absolutePath
                take.launch(FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", file))
            }.onFailure { camera?.let { File(it).delete() }; camera = null; error("未找到可用相机，可从相册选择图片。") }
        }, enabled = !busy) { Icon(Icons.Rounded.PhotoCamera, null); Text("拍照") }
    }
    pending?.let { path ->
        fun dismiss() { if (!busy) { File(path).delete(); pending = null } }
        Dialog(::dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Column(Modifier.fillMaxSize().background(Color(0xFF16221E)).safeDrawingPadding().padding(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(::dismiss) { Icon(Icons.Rounded.Close, "取消发送", tint = White) }
                    Label("发送给 $recipient", 18, White)
                }
                Box(Modifier.weight(1f), Alignment.Center) { Picture(path, ratio, true, Modifier.fillMaxWidth(), true) }
                Button({
                    if (!busy) {
                        busy = true
                        scope.launch {
                            try {
                                val saved = withContext(Dispatchers.IO) {
                                    PhotoFiles.save(ctx, File(path))
                                }
                                if (store.notes.value[id]?.deleted == true) saved.delete()
                                else { store.send(id, "", saved.absolutePath, ratio); sent() }
                                pending = null
                            } catch (e: java.io.IOException) { error("图片保存失败，请重试。") }
                            finally { busy = false }
                        }
                    }
                }, Modifier.align(Alignment.End), enabled = !busy) { Text("发送") }
            }
        }
    }
}
