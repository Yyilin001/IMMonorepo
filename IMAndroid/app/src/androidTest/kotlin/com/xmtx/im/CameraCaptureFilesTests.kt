package com.xmtx.im

import android.graphics.Bitmap
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.ResourceDimensions
import com.xmtx.im.platform.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

class CameraCaptureFilesTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private val folder get()=File(context.cacheDir,"camera-captures-v1")
    private fun file(photo: CameraPhoto)=File(folder,requireNotNull(photo.uri.lastPathSegment))
    @Test fun providerExposesOnlyPrivateCaptureFolderAndNormalizationReleasesRawFile()=runBlocking {
        val provider=context.packageManager.resolveContentProvider("${context.packageName}.camera",0)!!
        assertFalse(provider.exported);assertTrue(provider.grantUriPermissions)
        val permissions=context.packageManager.getPackageInfo(context.packageName,android.content.pm.PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assertFalse("android.permission.CAMERA" in permissions);assertFalse("android.permission.READ_MEDIA_IMAGES" in permissions)
        val outside=File(context.cacheDir,"not-a-camera-file.txt")
        assertTrue(runCatching { FileProvider.getUriForFile(context,"${context.packageName}.camera",outside) }.exceptionOrNull() is IllegalArgumentException)
        val capture=CameraCaptureFiles.create(context)
        try {
            val bitmap=Bitmap.createBitmap(120,80,Bitmap.Config.ARGB_8888)
            try { bitmap.eraseColor(android.graphics.Color.BLUE);context.contentResolver.openOutputStream(capture.uri,"w")!!.use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG,95,it)) } }
            finally { bitmap.recycle() }
            assertTrue(file(capture).exists());val photo=capture.prepare()
            assertEquals(ResourceDimensions(120,80),photo.dimensions);assertEquals("image/jpeg",photo.contentType)
            assertFalse(file(capture).exists())
        } finally { capture.close() }
    }
    @Test fun cleanupPreservesLiveCaptureAndRemovesOrphanWithoutAllowingTwoWriters()=runBlocking {
        val capture=CameraCaptureFiles.create(context)
        val orphan=File(folder,"capture-${UUID.randomUUID()}.jpg").apply { writeText("old process") }
        try {
            CameraCaptureFiles.cleanup(context);assertFalse(orphan.exists());assertTrue(file(capture).exists())
            assertTrue(runCatching { CameraCaptureFiles.create(context) }.exceptionOrNull() is IllegalStateException)
        } finally { capture.close();orphan.delete() }
        assertFalse(file(capture).exists());val next=CameraCaptureFiles.create(context)
        try { assertNotEquals(capture.uri,next.uri) } finally { next.close() }
    }
    @Test fun emptyAndOversizedCameraResultsAreRejectedAndDeleted()=runBlocking {
        for(oversized in listOf(false,true)) {
            val capture=CameraCaptureFiles.create(context)
            try {
                if(oversized) RandomAccessFile(file(capture),"rw").use { it.setLength(PhotoPreparation.maximumInputBytes.toLong()+1) }
                val error=runCatching { capture.prepare() }.exceptionOrNull()
                assertTrue(error is PhotoPreparationFailure)
                assertEquals(if(oversized) PhotoPreparationFailure.Reason.TooLarge else PhotoPreparationFailure.Reason.Unreadable,(error as PhotoPreparationFailure).reason)
                assertFalse(file(capture).exists())
            } finally { capture.close() }
        }
    }
}
