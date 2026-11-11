package com.xmtx.im

import android.graphics.Bitmap
import android.net.Uri
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class CameraEditorControllerTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val profile=ProfileView(actor,PublicIdentity(actor,PublicHandle("camera_owner"),"我的资料",AccountKind.Regular),null,ProfileState.Active,1,1)
    private suspend fun image(): NormalizedPhoto {
        val bitmap=Bitmap.createBitmap(120,80,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { bitmap.eraseColor(android.graphics.Color.BLUE);bitmap.compress(Bitmap.CompressFormat.JPEG,95,bytes) } finally { bitmap.recycle() }
        return PhotoPreparation().prepare(bytes.toByteString())
    }
    private class Capture(private val image: NormalizedPhoto): CameraPhoto {
        override val uri=Uri.parse("content://test/capture");var closed=false;var reads=0;var beforeRead: suspend ()->Unit={}
        override suspend fun prepare(): NormalizedPhoto { reads++;beforeRead();return image }
        override fun close() { closed=true }
    }
    private fun editor(scope: CoroutineScope,photo: NormalizedPhoto,create: suspend ()->CameraPhoto)=AvatarEditorController("editor",actor,scope,{profile},{photo},{p,_->p},{_,_->"intent"},{},{},{},create)
    private suspend fun until(condition: ()->Boolean) { withTimeout(5000) { while(!condition()) delay(10) } }
    @Test fun cameraReturnWaitsForForegroundIgnoresLibraryResultAndReleasesAfterNormalization()=runBlocking {
        val photo=image();val capture=Capture(photo);val editor=editor(this,photo) { capture };var launched:Uri?=null
        try {
            editor.foreground(true);editor.takePicture { launched=it };until { launched!=null }
            editor.picked(Uri.parse("content://test/late-library"));assertEquals(AvatarPhotoSource.Camera,editor.state.source)
            editor.foreground(false);assertFalse(capture.closed);editor.captured(true);assertEquals(0,capture.reads)
            editor.foreground(true);until { editor.state.photo!=null }
            assertSame(photo,editor.state.photo);assertTrue(editor.state.openCrop);assertTrue(capture.closed);assertNull(editor.state.source)
        } finally { editor.close() }
    }
    @Test fun cancelledResultAndMissingCameraReleaseOutputWithoutOpeningCrop()=runBlocking {
        val photo=image();val captures=mutableListOf<Capture>();val editor=editor(this,photo) { Capture(photo).also { captures+=it } }
        try {
            editor.foreground(true);editor.takePicture { };until { editor.state.source==AvatarPhotoSource.Camera }
            editor.captured(false);assertTrue(captures[0].closed);assertNull(editor.state.photo)
            editor.takePicture { throw android.content.ActivityNotFoundException() };until { editor.state.feedback!=null }
            assertTrue(captures[1].closed);assertNull(editor.state.source);assertFalse(editor.state.openCrop)
            assertTrue(editor.beginPick());editor.captured(true);assertEquals(AvatarPhotoSource.Library,editor.state.source)
        } finally { editor.close() }
    }
    @Test fun leavingDuringCameraAllocationClosesTransferredLeaseAndNeverLaunches()=runBlocking {
        val photo=image();val capture=Capture(photo);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var launches=0
        val editor=editor(this,photo) { entered.complete(Unit);release.await();capture }
        try {
            editor.foreground(true);editor.takePicture { launches++ };entered.await();editor.close();release.complete(Unit)
            until { capture.closed };assertEquals(0,launches);assertNull(editor.state.photo)
        } finally { release.complete(Unit);editor.close() }
    }
    @Test fun cancelledCameraDecodeCannotOverwriteAnotherSelectionAndAlwaysClosesRawFile()=runBlocking {
        val photo=image();val capture=Capture(photo);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        capture.beforeRead={ entered.complete(Unit);withContext(NonCancellable) { release.await() } }
        val editor=editor(this,photo) { capture }
        try {
            editor.foreground(true);editor.takePicture { };until { editor.state.source==AvatarPhotoSource.Camera };editor.captured(true);entered.await()
            editor.foreground(false);editor.foreground(true);editor.beginPick();editor.picked(Uri.parse("content://test/new-image"));until { editor.state.photo!=null }
            editor.crop(AvatarCrop(3f));val crop=editor.state.crop;release.complete(Unit);until { capture.closed };delay(50)
            assertEquals(crop,editor.state.crop);assertNull(editor.state.operation)
        } finally { release.complete(Unit);editor.close() }
    }
    @Test fun closingWhileExternalCameraIsOpenReleasesLeaseAndDropsLateResult()=runBlocking {
        val photo=image();val capture=Capture(photo);val editor=editor(this,photo) { capture }
        editor.foreground(true);editor.takePicture { };until { editor.state.source==AvatarPhotoSource.Camera }
        editor.foreground(false);editor.close();editor.captured(true)
        assertTrue(capture.closed);assertEquals(0,capture.reads);assertNull(editor.state.photo)
    }
}
