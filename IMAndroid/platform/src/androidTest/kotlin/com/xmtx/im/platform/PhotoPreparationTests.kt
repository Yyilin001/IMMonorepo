package com.xmtx.im.platform

import android.content.*
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.graphics.*
import android.net.Uri
import android.os.*
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.*
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.CRC32

class PhotoTestProvider: ContentProvider() {
    companion object {
        var opened=CountDownLatch(1);var release=CountDownLatch(1)
        fun uri(file: File)=Uri.parse("content://com.xmtx.im.platform.test.photos/${file.name}")
    }
    override fun onCreate()=true
    override fun getType(uri: Uri)="image/png" // Deliberately untrusted provider metadata.
    override fun query(uri: Uri,projection: Array<out String>?,selection: String?,selectionArgs: Array<out String>?,sortOrder: String?): Cursor?=null
    override fun insert(uri: Uri,values: ContentValues?): Uri?=null
    override fun update(uri: Uri,values: ContentValues?,selection: String?,selectionArgs: Array<out String>?)=0
    override fun delete(uri: Uri,selection: String?,selectionArgs: Array<out String>?)=0
    override fun openAssetFile(uri: Uri,mode: String): AssetFileDescriptor {
        if(uri.lastPathSegment=="slow") {
            val pipe=ParcelFileDescriptor.createReliablePipe()
            Thread { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { release.await(10,TimeUnit.SECONDS) } }.start()
            opened.countDown();return AssetFileDescriptor(pipe[0],0,AssetFileDescriptor.UNKNOWN_LENGTH)
        }
        val file=File(requireNotNull(context).filesDir,requireNotNull(uri.lastPathSegment))
        val fd=ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(fd,0,if(uri.getQueryParameter("unknown")=="true") AssetFileDescriptor.UNKNOWN_LENGTH else file.length())
    }
}

class PhotoPreparationTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private val processor=PhotoPreparation()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun bitmap(width: Int=200,height: Int=100)=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888).apply {
        val canvas=Canvas(this);val paint=Paint()
        listOf(Color.RED,Color.GREEN,Color.BLUE,Color.YELLOW).forEachIndexed { i,color ->
            paint.color=color;val x=(i%2)*width/2f;val y=(i/2)*height/2f
            canvas.drawRect(x,y,x+width/2f,y+height/2f,paint)
        }
    }
    private fun encoded(bitmap: Bitmap,type: Bitmap.CompressFormat=Bitmap.CompressFormat.PNG): ByteString {
        val bytes=ByteString.newOutput();try { assertTrue(bitmap.compress(type,100,bytes));return bytes.toByteString() } finally { bitmap.recycle() }
    }
    private fun file(data: ByteString)=File.createTempFile("photo-test-",".jpg",context.filesDir).apply { outputStream().use { data.writeTo(it) } }
    private fun assertColor(expected: Int,actual: Int) {
        assertTrue("Unexpected red channel",kotlin.math.abs(Color.red(expected)-Color.red(actual))<35)
        assertTrue("Unexpected green channel",kotlin.math.abs(Color.green(expected)-Color.green(actual))<35)
        assertTrue("Unexpected blue channel",kotlin.math.abs(Color.blue(expected)-Color.blue(actual))<35)
    }
    private suspend fun failure(reason: PhotoPreparationFailure.Reason,body: suspend ()->Unit) {
        val error=runCatching { body() }.exceptionOrNull();assertTrue(error is PhotoPreparationFailure);assertEquals(reason,(error as PhotoPreparationFailure).reason)
    }

    @Test fun providerNormalizesAllEightExifOrientationsAndDropsLocation()=runBlocking {
        val corners=arrayOf(intArrayOf(0,1,2,3),intArrayOf(1,0,3,2),intArrayOf(3,2,1,0),intArrayOf(2,3,0,1),
            intArrayOf(0,2,1,3),intArrayOf(2,0,3,1),intArrayOf(3,1,2,0),intArrayOf(1,3,0,2))
        val colors=intArrayOf(Color.RED,Color.GREEN,Color.BLUE,Color.YELLOW)
        for(orientation in 1..8) {
            val source=file(encoded(bitmap(),Bitmap.CompressFormat.JPEG))
            try {
                ExifInterface(source).apply { setAttribute(ExifInterface.TAG_ORIENTATION,orientation.toString());setLatLong(31.2,121.5);saveAttributes() }
                val before=context.filesDir.list()!!.toSet()
                val photo=processor.prepare(context.contentResolver,PhotoTestProvider.uri(source))
                assertEquals(before,context.filesDir.list()!!.toSet());assertEquals("image/jpeg",photo.contentType)
                assertEquals(ResourceDimensions(if(orientation>=5) 100 else 200,if(orientation>=5) 200 else 100),photo.dimensions)
                val metadata=ExifInterface(photo.data.newInput());assertNull(metadata.latLong)
                assertEquals(ExifInterface.ORIENTATION_UNDEFINED,metadata.getAttributeInt(ExifInterface.TAG_ORIENTATION,ExifInterface.ORIENTATION_UNDEFINED))
                val decoded=BitmapFactory.decodeStream(photo.data.newInput())!!
                try { corners[orientation-1].forEachIndexed { i,color -> assertColor(colors[color],decoded.getPixel(decoded.width*(if(i%2==0) 1 else 3)/4,decoded.height*(if(i/2==0) 1 else 3)/4)) } }
                finally { decoded.recycle() }
            } finally { source.delete() }
        }
    }

    @Test fun largeInputIsBoundedAndSelectedCropMatchesIosSquareRules()=runBlocking {
        val large=processor.prepare(encoded(bitmap(5000,100)))
        assertEquals(2048,large.dimensions.width);assertTrue(large.dimensions.height in 40..41)
        val photo=processor.prepare(encoded(bitmap()))
        val cropped=processor.crop(photo,PhotoCrop(0.5,0.0,0.5,0.5))
        assertEquals(ResourceDimensions(50,50),cropped.dimensions);assertEquals("image/jpeg",cropped.contentType)
        val decoded=BitmapFactory.decodeStream(cropped.data.newInput())!!
        try { assertColor(Color.GREEN,decoded.getPixel(25,25)) } finally { decoded.recycle() }
        val largeSquare=processor.prepare(encoded(bitmap(2048,2048)))
        assertEquals(ResourceDimensions(1024,1024),processor.crop(largeSquare,PhotoCrop(0.0,0.0,1.0,1.0)).dimensions)
        assertEquals(ResourceDimensions(100,100),processor.crop(photo,PhotoCrop(-0.2,-0.1,1.2,1.1)).dimensions)
        for(crop in listOf(PhotoCrop(0.0,0.0,0.0,1.0),PhotoCrop(2.0,2.0,1.0,1.0),PhotoCrop(Double.NaN,0.0,1.0,1.0)))
            failure(PhotoPreparationFailure.Reason.InvalidCrop) { processor.crop(photo,crop) }
    }

    @Test fun actualTransparencyStaysPngButAvatarCompositesOnWhite()=runBlocking {
        val opaque=processor.prepare(encoded(bitmap(128,96)));assertEquals("image/jpeg",opaque.contentType)
        val transparent=bitmap(128,96).apply { setPixel(117,83,Color.TRANSPARENT) }
        assertEquals("image/png",processor.prepare(encoded(transparent)).contentType)
        val empty=Bitmap.createBitmap(80,60,Bitmap.Config.ARGB_8888)
        val photo=processor.prepare(encoded(empty));assertEquals("image/png",photo.contentType)
        val crop=processor.crop(photo,PhotoCrop(0.0,0.0,1.0,1.0));val decoded=BitmapFactory.decodeStream(crop.data.newInput())!!
        try { assertColor(Color.WHITE,decoded.getPixel(10,10)) } finally { decoded.recycle() }
    }

    @Test fun rejectsInvalidPixelsOversizedProvidersAndBoundedEncoderOverflow()=runBlocking {
        failure(PhotoPreparationFailure.Reason.Unreadable) { processor.prepare(ByteString.copyFromUtf8("not an image")) }
        val valid=encoded(bitmap(32,32))
        failure(PhotoPreparationFailure.Reason.TooLarge) { processor.prepare(valid,8) }
        val hugeHeader=valid.toByteArray();ByteBuffer.wrap(hugeHeader,16,8).putInt(10000).putInt(9000)
        val crc=CRC32().apply { update(hugeHeader,12,17) };ByteBuffer.wrap(hugeHeader,29,4).putInt(crc.value.toInt())
        failure(PhotoPreparationFailure.Reason.Unreadable) { processor.prepare(ByteString.copyFrom(hugeHeader)) }
        val source=File.createTempFile("photo-too-large-",".bin",context.filesDir)
        try {
            RandomAccessFile(source,"rw").use { it.setLength(PhotoPreparation.maximumInputBytes+1L) }
            failure(PhotoPreparationFailure.Reason.TooLarge) { processor.prepare(context.contentResolver,PhotoTestProvider.uri(source)) }
            failure(PhotoPreparationFailure.Reason.TooLarge) { processor.prepare(context.contentResolver,PhotoTestProvider.uri(source).buildUpon().appendQueryParameter("unknown","true").build()) }
        } finally { source.delete() }
        assertTrue(runCatching { processor.prepare(context.contentResolver,Uri.parse("https://example.test/photo.jpg")) }.exceptionOrNull() is IllegalArgumentException)
    }

    @Test fun cancelledProviderPipeDrainsAndReleasesSharedDecoder()=runBlocking {
        PhotoTestProvider.opened=CountDownLatch(1);PhotoTestProvider.release=CountDownLatch(1)
        val work=launch { processor.prepare(context.contentResolver,Uri.parse("content://com.xmtx.im.platform.test.photos/slow")) }
        try {
            withContext(Dispatchers.IO) { assertTrue(PhotoTestProvider.opened.await(5,TimeUnit.SECONDS)) };delay(100)
            withTimeout(5000) { work.cancelAndJoin() };assertTrue(work.isCancelled)
            withTimeout(5000) { assertEquals(ResourceDimensions(32,32),processor.prepare(encoded(bitmap(32,32))).dimensions) }
        } finally { PhotoTestProvider.release.countDown();work.cancelAndJoin() }
    }

    @Test fun normalizedBytesPublishOneAccountOriginalWithDimensionsAndDeduplicate()=runBlocking {
        val store=SqliteClientStore(context,UserId(id()),DeviceId(id()));val files=ManagedResourceFiles(context,store)
        try {
            val photo=processor.crop(processor.prepare(encoded(bitmap())),PhotoCrop(0.5,0.0,0.5,1.0))
            val before=context.filesDir.list()!!.toSet();val first=files.importPhoto(photo,ResourceUsage.UserAvatar)
            val second=files.importPhoto(photo,ResourceUsage.UserAvatar)
            assertEquals(before,context.filesDir.list()!!.toSet());assertEquals(photo.dimensions,first.dimensions)
            assertEquals(photo.byteCount,first.byteCount);assertEquals(first.file,second.file);assertEquals(1,store.resourceFiles().size)
            files.withOriginal(selection=first.id) { assertEquals(photo.data,ByteString.readFrom(it.inputStream())) }
            files.discardSelection(first.id);files.cleanup();assertEquals(1,store.resourceFiles().size)
            files.discardSelection(second.id);files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close() }
    }

    @Test fun cancellationAfterPhotoPublicationDoesNotLeakSelection()=runBlocking {
        val store=SqliteClientStore(context,UserId(id()),DeviceId(id()));lateinit var importing: Job
        val files=ManagedResourceFiles(context,store,checkpoint={ if(it==ManagedResourceFiles.PublicationCheckpoint.Published) importing.cancel() })
        try {
            val photo=processor.prepare(encoded(bitmap(32,32)))
            importing=launch { files.importPhoto(photo,ResourceUsage.UserAvatar) };withTimeout(5000) { importing.join() }
            assertTrue(importing.isCancelled);assertTrue(files.selected(ResourceUsage.UserAvatar).isEmpty())
            files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close() }
    }
}
