package com.xmtx.im.platform

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.CRC32

class MessageImagePreparationTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun image(width: Int,height: Int,jpeg: Boolean=false): File {
        val file=File.createTempFile("message-image-",if(jpeg) ".jpg" else ".png",context.filesDir)
        val bitmap=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888)
        try { bitmap.eraseColor(android.graphics.Color.BLUE);file.outputStream().use { assertTrue(bitmap.compress(if(jpeg) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG,90,it)) } } finally { bitmap.recycle() }
        return file
    }
    @Test fun sampledOriginalRespectsExifOrientationAndProducesBoundedImmutablePixels()=runBlocking<Unit> {
        val file=image(3000,1800,true)
        try {
            ExifInterface(file).apply { setAttribute(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_ROTATE_90.toString());setAttribute(ExifInterface.TAG_ARTIST,"private metadata");saveAttributes() }
            val result=MessageImagePreparation().prepare(file)
            assertEquals(900,result.dimensions.width);assertEquals(1500,result.dimensions.height);assertTrue(result.byteCount<=20*1024*1024)
            val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true };result.data.newInput().use { BitmapFactory.decodeStream(it,null,bounds) }
            assertEquals(900,bounds.outWidth);assertEquals(1500,bounds.outHeight)
            result.data.newInput().use { assertNull(ExifInterface(it).getAttribute(ExifInterface.TAG_ARTIST)) }
        } finally { file.delete() }
    }
    @Test fun invalidAndExcessivePixelBoundsFailBeforeAllocatingDisplayBitmap()=runBlocking<Unit> {
        val file=image(1,1)
        try {
            val bytes=file.readBytes()
            for(height in listOf(100000,1)) {
                ByteBuffer.wrap(bytes).putInt(16,100000).putInt(20,height)
                val checksum=CRC32().apply { update(bytes,12,17) };ByteBuffer.wrap(bytes).putInt(29,checksum.value.toInt());file.writeBytes(bytes)
                assertTrue(runCatching { MessageImagePreparation().prepare(file) }.isFailure)
            }
            file.writeText("not an image");assertTrue(runCatching { MessageImagePreparation().prepare(file) }.isFailure)
        } finally { file.delete() }
    }
    @Test fun cancellationBeforeDecodeDoesNotPublishAnImage()=runBlocking<Unit> {
        val file=image(320,200);var returned=false
        try { val task=launch(start=CoroutineStart.LAZY) { MessageImagePreparation().prepare(file);returned=true };task.cancelAndJoin();assertFalse(returned) }
        finally { file.delete() }
    }
    @Test fun localThumbnailSamplesTheOriginalAndStripsExifWithoutLoadingWholeFile()=runBlocking<Unit> {
        val file=image(3000,1800,true)
        try {
            ExifInterface(file).apply { setAttribute(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_ROTATE_90.toString());setAttribute(ExifInterface.TAG_ARTIST,"private");saveAttributes() }
            val thumbnail=MessageImagePreparation().thumbnail(file)
            assertTrue(thumbnail.dimensions.width in 1..256);assertTrue(thumbnail.dimensions.height in 1..256)
            assertTrue(thumbnail.dimensions.height>thumbnail.dimensions.width);assertTrue(thumbnail.byteCount<=512*1024)
            thumbnail.data.newInput().use { assertNull(ExifInterface(it).getAttribute(ExifInterface.TAG_ARTIST)) }
        } finally { file.delete() }
    }
    @Test fun malformedOriginalCannotProduceALocalThumbnail()=runBlocking<Unit> {
        val file=image(1,1)
        try { file.writeText("not an image");assertTrue(runCatching { MessageImagePreparation().thumbnail(file) }.isFailure) }
        finally { file.delete() }
    }

}
