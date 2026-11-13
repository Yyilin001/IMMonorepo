package com.xmtx.im

import android.content.Context
import android.graphics.*
import android.net.Uri
import android.util.Base64
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/** Device image/QR I/O only; no invitation parsing, upload protocol, account policy or persistence. */
internal object SharedImageTools {
    suspend fun read(context: Context, uri: Uri): Bitmap = withContext(Dispatchers.IO) {
        val bytes = context.contentResolver.openInputStream(uri)?.use { stream ->
            val out = ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) { ensureActive(); val n = stream.read(buffer); if (n < 0) break; require(out.size() + n <= 10 * 1024 * 1024); out.write(buffer, 0, n) }; out.toByteArray()
        } ?: error("image unavailable")
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            require(info.size.width in 1..16384 && info.size.height in 1..16384)
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val ratio = minOf(1.0, 2048.0 / maxOf(info.size.width, info.size.height))
            decoder.setTargetSize(maxOf(1, (info.size.width * ratio).toInt()), maxOf(1, (info.size.height * ratio).toInt()))
        }
    }
    fun crop(bitmap: Bitmap, zoom: Float, x: Float, y: Float): String {
        require(zoom.isFinite() && zoom in 1f..3f && x in 0f..1f && y in 0f..1f)
        val side = maxOf(1, (minOf(bitmap.width, bitmap.height) / zoom).toInt())
        val left = ((bitmap.width - side) * x).toInt(); val top = ((bitmap.height - side) * y).toInt()
        val output = Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(output); canvas.drawColor(Color.WHITE)
            canvas.drawBitmap(bitmap, Rect(left, top, left + side, top + side), Rect(0, 0, 512, 512), Paint(Paint.FILTER_BITMAP_FLAG))
            val bytes = ByteArrayOutputStream().also { check(output.compress(Bitmap.CompressFormat.JPEG, 85, it)) }.toByteArray()
            require(bytes.size <= 524288)
            return Base64.encodeToString(bytes, Base64.NO_WRAP)
        } finally { output.recycle() }
    }
    fun qr(bitmap: Bitmap): String {
        val pixels = IntArray(bitmap.width * bitmap.height); bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val reader = MultiFormatReader()
        return try { reader.decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(bitmap.width, bitmap.height, pixels))), mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))).text.also { require(it.length <= 1024) } }
        finally { reader.reset() }
    }
}
internal data class SharedImageState(val jpeg: String? = null, val busy: Boolean = false, val error: String? = null) {
    override fun toString() = "SharedImageState(<private>)"
}
internal class SharedImageController(private val context: Context) {
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var task: Job? = null
    private var original: Bitmap? = null
    private val mutable = MutableStateFlow(SharedImageState())
    val state = mutable.asStateFlow()
    fun load(uri: Uri) { val previous = task; previous?.cancel(); task = owner.launch {
        previous?.join()
        mutable.value = SharedImageState(busy = true)
        try { val bitmap = SharedImageTools.read(context, uri); ensureActive(); original?.recycle(); original = bitmap
            mutable.value = SharedImageState(jpeg = withContext(Dispatchers.Default) { SharedImageTools.crop(bitmap, 1f, .5f, .5f) }) }
        catch (e: CancellationException) { throw e } catch (_: Exception) { mutable.value = SharedImageState(error = "无法读取图片，请选择不超过 10 MiB 的图片") }
    } }
    fun crop(zoom: Float, x: Float, y: Float) { if (mutable.value.busy) return; val bitmap = original ?: return
        task = owner.launch { mutable.value = mutable.value.copy(busy = true)
            try { mutable.value = SharedImageState(jpeg = withContext(Dispatchers.Default) { SharedImageTools.crop(bitmap, zoom, x, y) }) }
            catch (e: CancellationException) { throw e } catch (_: Exception) { mutable.value = SharedImageState(error = "裁剪失败") }
        }
    }
    fun scan(uri: Uri, found: (String) -> Unit) { val previous = task; previous?.cancel(); task = owner.launch {
        previous?.join()
        mutable.value = SharedImageState(busy = true)
        try { val bitmap = SharedImageTools.read(context, uri)
            val text = try { withContext(Dispatchers.Default) { SharedImageTools.qr(bitmap) } } finally { bitmap.recycle() }
            ensureActive(); mutable.value = SharedImageState(); found(text)
        } catch (e: CancellationException) { throw e } catch (_: Exception) { mutable.value = SharedImageState(error = "未识别到二维码") }
    } }
    fun clear() { task?.cancel(); task = null; original = null; mutable.value = SharedImageState() }
    fun close() { clear(); owner.cancel() }
}
