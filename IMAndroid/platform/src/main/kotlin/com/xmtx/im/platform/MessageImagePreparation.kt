package com.xmtx.im.platform

import android.graphics.*
import androidx.exifinterface.media.ExifInterface
import com.google.protobuf.ByteString
import com.xmtx.im.client.ResourceDimensions
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.OutputStream
import kotlin.math.max

/** Decode while the account file borrow is held. Original encoded bytes are never loaded as one array. */
class MessageImagePreparation {
    suspend fun prepare(file: File): NormalizedPhoto=decode(file,2048,20*1024*1024)
    suspend fun thumbnail(file: File): NormalizedPhoto=decode(file,256,512*1024)
    private suspend fun decode(file: File,maximumSide: Int,maximumBytes: Int): NormalizedPhoto=withContext(Dispatchers.IO) { processing.withLock {
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        file.inputStream().use { BitmapFactory.decodeStream(it,null,bounds) }
        if(bounds.outWidth<=0 || bounds.outHeight<=0 || bounds.outWidth>32768 || bounds.outHeight>32768 || bounds.outWidth>80_000_000/bounds.outHeight) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.Unreadable)
        val exif=file.inputStream().use { ExifInterface(it) }
        var sample=1;while((max(bounds.outWidth,bounds.outHeight)+sample-1)/sample>maximumSide) sample*=2
        currentCoroutineContext().ensureActive()
        var bitmap=file.inputStream().use { BitmapFactory.decodeStream(it,null,BitmapFactory.Options().apply { inSampleSize=sample;inPreferredConfig=Bitmap.Config.ARGB_8888;inScaled=false }) }
            ?: throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.Unreadable)
        try {
            currentCoroutineContext().ensureActive()
            val matrix=Matrix().apply { if(exif.isFlipped) postScale(-1f,1f);postRotate(exif.rotationDegrees.toFloat()) }
            if(!matrix.isIdentity) {
                val oriented=Bitmap.createBitmap(bitmap,0,0,bitmap.width,bitmap.height,matrix,true)
                if(oriented!==bitmap) { bitmap.recycle();bitmap=oriented }
            }
            require(bitmap.width in 1..maximumSide && bitmap.height in 1..maximumSide)
            val output=ByteString.newOutput();var written=0
            val bounded=object: OutputStream() {
                override fun write(value: Int) { if(written>=maximumBytes) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.TooLarge);output.write(value);written++ }
                override fun write(bytes: ByteArray,offset: Int,length: Int) { if(length>maximumBytes-written) throw PhotoPreparationFailure(PhotoPreparationFailure.Reason.TooLarge);output.write(bytes,offset,length);written+=length }
            }
            check(bitmap.compress(Bitmap.CompressFormat.PNG,100,bounded));currentCoroutineContext().ensureActive()
            NormalizedPhoto(output.toByteString(),"image/png",ResourceDimensions(bitmap.width,bitmap.height))
        } finally { bitmap.recycle() }
    } }
    private companion object { val processing=Mutex() }
}
