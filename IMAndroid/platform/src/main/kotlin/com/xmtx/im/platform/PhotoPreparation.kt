package com.xmtx.im.platform

import android.content.ContentResolver
import android.graphics.*
import android.net.Uri
import android.os.CancellationSignal
import androidx.exifinterface.media.ExifInterface
import com.google.protobuf.ByteString
import com.xmtx.im.client.ResourceDimensions
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.*
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.*

/** Encoded immutable pixels, never a mutable Bitmap or provider URI in application state. */
class NormalizedPhoto internal constructor(val data: ByteString,val contentType: String,val dimensions: ResourceDimensions) {
    val byteCount: Long get()=data.size().toLong()
    override fun toString()="NormalizedPhoto($contentType, ${dimensions.width}x${dimensions.height}, $byteCount bytes)"
}
data class PhotoCrop(val x: Double,val y: Double,val width: Double,val height: Double)
class PhotoPreparationFailure(val reason: Reason): IOException(when(reason) {
    Reason.TooLarge->"图片超过处理上限";Reason.Unreadable->"无法读取这张图片";Reason.InvalidCrop->"请选择有效的裁剪区域"
}) { enum class Reason { TooLarge,Unreadable,InvalidCrop } }

/** Shared decoder budget. Raw provider bytes are bounded and never copied to disk. */
class PhotoPreparation {
    companion object {
        const val maximumInputBytes=50*1024*1024
        const val maximumPixels=80_000_000
        const val maximumSide=2048
        private val processing=Mutex()
    }
    suspend fun prepare(resolver: ContentResolver,uri: Uri,maximumOutputBytes: Int=maximumInputBytes): NormalizedPhoto =
        withContext(Dispatchers.IO) { processing.withLock {
            require(uri.scheme==ContentResolver.SCHEME_CONTENT) { "请选择系统提供的图片" }
            checkLimit(maximumOutputBytes)
            val encoded=readProvider(resolver,uri)
            prepareLocked(encoded,maximumOutputBytes)
        } }

    suspend fun prepare(encoded: ByteString,maximumOutputBytes: Int=maximumInputBytes): NormalizedPhoto =
        withContext(Dispatchers.IO) { processing.withLock { checkLimit(maximumOutputBytes);prepareLocked(encoded,maximumOutputBytes) } }

    private suspend fun prepareLocked(encoded: ByteString,limit: Int): NormalizedPhoto {
        val bitmap=decode(encoded)
        try { return encode(bitmap,if(transparent(bitmap)) "image/png" else "image/jpeg",85,limit) }
        finally { bitmap.recycle() }
    }

    /** Coordinates refer to the oriented, normalized image. Like iOS, intersect, round out, then square. */
    suspend fun crop(photo: NormalizedPhoto,crop: PhotoCrop,maximumOutputBytes: Int=maximumInputBytes): NormalizedPhoto =
        withContext(Dispatchers.IO) { processing.withLock {
            checkLimit(maximumOutputBytes)
            if(!crop.x.isFinite() || !crop.y.isFinite() || !crop.width.isFinite() || !crop.height.isFinite() || crop.width<=0 || crop.height<=0)
                throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.InvalidCrop)
            val bitmap=decode(photo.data)
            try {
                val left=max(0.0,crop.x*bitmap.width);val top=max(0.0,crop.y*bitmap.height)
                val right=min(bitmap.width.toDouble(),(crop.x+crop.width)*bitmap.width)
                val bottom=min(bitmap.height.toDouble(),(crop.y+crop.height)*bitmap.height)
                if(right<=left || bottom<=top) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.InvalidCrop)
                val x=floor(left).toInt();val y=floor(top).toInt()
                val side=min(ceil(right).toInt()-x,ceil(bottom).toInt()-y)
                if(side<1) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.InvalidCrop)
                val output=Bitmap.createBitmap(min(1024,side),min(1024,side),Bitmap.Config.ARGB_8888)
                try {
                    output.eraseColor(Color.WHITE)
                    Canvas(output).drawBitmap(bitmap,Rect(x,y,x+side,y+side),Rect(0,0,output.width,output.height),Paint(Paint.FILTER_BITMAP_FLAG))
                    encode(output,"image/jpeg",88,maximumOutputBytes)
                } finally { output.recycle() }
            } finally { bitmap.recycle() }
        } }

    private suspend fun readProvider(resolver: ContentResolver,uri: Uri): ByteString = coroutineScope {
        val signal=CancellationSignal();val active=AtomicReference<InputStream?>()
        // Cancellation closes a pipe as well as cancelling a provider which has not returned its descriptor yet.
        val closer=launch(start=CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() } finally { signal.cancel();runCatching { active.getAndSet(null)?.close() } }
        }
        try {
            val descriptor=resolver.openAssetFileDescriptor(uri,"r",signal) ?: unreadable()
            descriptor.use {
                if(it.length>maximumInputBytes) tooLarge()
                it.createInputStream().use { input ->
                    active.set(input);currentCoroutineContext().ensureActive()
                    val output=ByteString.newOutput(64*1024);val buffer=ByteArray(64*1024);var count=0
                    while(true) {
                        currentCoroutineContext().ensureActive()
                        val read=input.read(buffer,0,min(buffer.size,maximumInputBytes-count+1))
                        if(read<0) break
                        if(read==0) { val byte=input.read();if(byte<0) break;if(count==maximumInputBytes) tooLarge();output.write(byte);count++ }
                        else { if(read>maximumInputBytes-count) tooLarge();output.write(buffer,0,read);count+=read }
                    }
                    currentCoroutineContext().ensureActive();if(count==0) unreadable();output.toByteString()
                }
            }
        } catch(error: Exception) {
            currentCoroutineContext().ensureActive()
            if(error is PhotoPreparationFailure) throw error
            unreadable()
        } finally { closer.cancelAndJoin() }
    }

    private suspend fun decode(encoded: ByteString): Bitmap {
        currentCoroutineContext().ensureActive()
        if(encoded.size()>maximumInputBytes) tooLarge()
        if(encoded.isEmpty) unreadable()
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        encoded.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
        if(bounds.outWidth<=0 || bounds.outHeight<=0 || bounds.outWidth>maximumPixels/bounds.outHeight) unreadable()
        val exif=try { encoded.newInput().use { ExifInterface(it) } } catch(_: IOException) { unreadable() }
        var sample=1
        while(max(bounds.outWidth,bounds.outHeight)/sample>maximumSide*2) sample*=2
        val options=BitmapFactory.Options().apply { inSampleSize=sample;inPreferredConfig=Bitmap.Config.ARGB_8888;inScaled=false }
        var bitmap=encoded.newInput().use { BitmapFactory.decodeStream(it,null,options) } ?: unreadable()
        try {
            currentCoroutineContext().ensureActive()
            val largest=max(bitmap.width,bitmap.height)
            if(largest>maximumSide) {
                val ratio=maximumSide.toDouble()/largest
                val scaled=Bitmap.createScaledBitmap(bitmap,max(1,(bitmap.width*ratio).roundToInt()),max(1,(bitmap.height*ratio).roundToInt()),true)
                if(scaled!==bitmap) { bitmap.recycle();bitmap=scaled }
            }
            val matrix=Matrix()
            if(exif.isFlipped) matrix.postScale(-1f,1f)
            matrix.postRotate(exif.rotationDegrees.toFloat())
            if(!matrix.isIdentity) {
                val rotated=Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,matrix,true)
                if(rotated!==bitmap) { bitmap.recycle();bitmap=rotated }
            }
            currentCoroutineContext().ensureActive();return bitmap
        } catch(error: Throwable) { bitmap.recycle();throw error }
    }

    private suspend fun transparent(bitmap: Bitmap): Boolean {
        if(!bitmap.hasAlpha()) return false
        val row=IntArray(bitmap.width)
        for(y in 0 until bitmap.height) {
            currentCoroutineContext().ensureActive();bitmap.getPixels(row,0,bitmap.width,0,y,bitmap.width,1)
            if(row.any { Color.alpha(it)!=255 }) return true
        }
        return false
    }
    private suspend fun encode(bitmap: Bitmap,type: String,quality: Int,limit: Int): NormalizedPhoto {
        val job=currentCoroutineContext().job;val bytes=ByteString.newOutput(64*1024);var exceeded=false;var count=0
        val output=object: OutputStream() {
            override fun write(value: Int) { job.ensureActive();if(count>=limit) { exceeded=true;tooLarge() };bytes.write(value);count++ }
            override fun write(buffer: ByteArray,offset: Int,length: Int) {
                job.ensureActive();if(length>limit-count) { exceeded=true;tooLarge() };bytes.write(buffer,offset,length);count+=length
            }
        }
        val success=bitmap.compress(if(type=="image/png") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG,quality,output)
        job.ensureActive();if(exceeded) tooLarge();if(!success || count==0) unreadable()
        return NormalizedPhoto(bytes.toByteString(),type,ResourceDimensions(bitmap.width,bitmap.height))
    }
    private fun checkLimit(limit: Int) { require(limit in 1..maximumInputBytes) }
    private fun tooLarge(): Nothing=throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.TooLarge)
    private fun unreadable(): Nothing=throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.Unreadable)
}
