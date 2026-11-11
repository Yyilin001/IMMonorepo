package com.xmtx.im.platform

import android.content.Context
import android.util.Size
import androidx.camera.core.*
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.xmtx.im.client.InvitationSecret
import com.xmtx.im.client.decodeInvitationQr
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One visible scanner owns only its own use cases. Closing fences queued provider/frame callbacks. */
class InvitationCameraSession(context: Context, private val owner: LifecycleOwner, view: PreviewView,
    private val found: (InvitationSecret) -> Unit, private val unavailable: () -> Unit) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val delivered = AtomicBoolean(false)
    private val main = ContextCompat.getMainExecutor(context)
    private val executor = Executors.newSingleThreadExecutor()
    private val preview = Preview.Builder().build().apply { surfaceProvider = view.surfaceProvider }
    private val analysis = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(
            ResolutionStrategy(Size(1280,720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)).build()).build()
    private var provider: ProcessCameraProvider? = null
    init {
        analysis.setAnalyzer(executor, InvitationFrameAnalyzer({ !closed.get() && !delivered.get() }) { value ->
            main.execute {
                if (!closed.get() && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) && delivered.compareAndSet(false,true)) found(value)
            }
        })
        val future = ProcessCameraProvider.getInstance(context.applicationContext)
        future.addListener({
            if (!closed.get()) try {
                val camera = future.get(); provider = camera
                val selector = when {
                    camera.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                    camera.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                    else -> throw IllegalStateException()
                }
                camera.bindToLifecycle(owner, selector, preview, analysis)
            } catch (_: Exception) { close(); unavailable() }
        }, main)
    }
    override fun close() {
        if (!closed.compareAndSet(false,true)) return
        analysis.clearAnalyzer()
        provider?.unbind(preview,analysis)
        executor.shutdown()
    }
}

internal fun decodeFrame(frame: ImageProxy): InvitationSecret? {
    val crop = frame.cropRect
    val width = crop.width(); val height = crop.height()
    if (width !in 1..2048 || height !in 1..2048 || crop.left < 0 || crop.top < 0 || crop.right > frame.width || crop.bottom > frame.height) return null
    val plane = frame.planes.firstOrNull() ?: return null
    if (plane.rowStride <= 0 || plane.pixelStride <= 0) return null
    val buffer = plane.buffer.duplicate()
    val start = buffer.position().toLong()
    val last = start + (crop.bottom-1L)*plane.rowStride + (crop.right-1L)*plane.pixelStride
    if (last >= buffer.limit()) return null
    val bytes = ByteArray(width*height)
    for (y in 0 until height) for (x in 0 until width) {
        bytes[y*width+x] = buffer.get((start+(crop.top+y).toLong()*plane.rowStride+(crop.left+x).toLong()*plane.pixelStride).toInt())
    }
    return decodeInvitationQr(width,height,bytes)
}

internal class InvitationFrameAnalyzer(private val accepting: () -> Boolean,
    private val found: (InvitationSecret) -> Unit) : ImageAnalysis.Analyzer {
    override fun analyze(image: ImageProxy) {
        try {
            if (accepting()) {
                val value = try { decodeFrame(image) } catch (_: Exception) { null }
                if (value != null) found(value)
            }
        } finally { image.close() }
    }
}
