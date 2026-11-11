package com.xmtx.im

import android.graphics.Bitmap
import android.net.Uri
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class GroupAvatarEditorControllerTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private fun access(revision: Long=0,canManage: Boolean=true,maximum: Long?=1000000,deadline: Long=System.nanoTime()+60000000000)=GroupAvatarManagementAccess(
        GroupAvatarEditAuthority(GroupAvatarPresentation(actor,device,GroupAvatarState(room,null,revision),1,null,canManage,null,1000,61000,1000,deadline,null),GroupAvatarFence("epoch",0,1,true)),maximum)
    private suspend fun image(): NormalizedPhoto {
        val bitmap=Bitmap.createBitmap(60,40,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { bitmap.eraseColor(android.graphics.Color.GREEN);bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes) } finally { bitmap.recycle() }
        return PhotoPreparation().prepare(bytes.toByteString())
    }
    private suspend fun until(test: ()->Boolean) { withTimeout(5000) { while(!test()) delay(10) } }
    @Test fun pickerDefersUntilForegroundAndEditingPixelsSurviveRotationWithoutAuthority()=runBlocking {
        val photo=image();var reads=0
        val editor=GroupAvatarEditorController("editor",room,this,{access()},{reads++;photo},{p,_->p},{_,_->"intent"},{_,_,_->},{})
        try {
            editor.foreground(true);until { editor.state.authorized() };assertTrue(editor.beginPick())
            editor.foreground(false);editor.picked(Uri.parse("content://test/image"));assertEquals(0,reads);assertFalse(editor.state.authorized())
            editor.foreground(true);until { editor.state.photo!=null && !editor.state.busy };editor.changeCrop(AvatarCrop(2f,0.7f,0.5f));val crop=editor.state.crop
            editor.foreground(false);assertSame(photo,editor.state.photo);assertEquals(crop,editor.state.crop);assertNull(editor.state.deadlineNanos)
            editor.foreground(true);until { editor.state.authorized() };assertEquals(crop,editor.state.crop)
            editor.close();editor.picked(Uri.parse("content://test/late"));assertNull(editor.state.photo)
        } finally { editor.close() }
    }
    @Test fun staleRevisionOrLostManagementCannotSubmitAfterCropping()=runBlocking {
        val photo=image();var current=access();var submitted=0
        val editor=GroupAvatarEditorController("editor",room,this,{current},{photo},{p,_->p},{_,_->submitted++;"intent"},{_,_,_->},{})
        try {
            editor.foreground(true);until { editor.state.authorized() };editor.beginPick();editor.picked(Uri.parse("content://test/photo"));until { editor.state.photo!=null && !editor.state.busy }
            current=access(1);editor.save();until { !editor.state.busy };assertEquals(0,submitted);assertSame(photo,editor.state.photo)
            editor.refresh();until { editor.state.revision==1L };current=access(1,false);editor.save();until { !editor.state.busy };assertEquals(0,submitted)
        } finally { editor.close() }
    }
    @Test fun cancellingPreparationSuppressesLateSaveAndExplicitResaveUsesFrozenCrop()=runBlocking {
        val photo=image();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var block=true;var saves=0;var observed:PhotoCrop?=null
        val editor=GroupAvatarEditorController("editor",room,this,{access()},{photo},{p,crop -> observed=crop;if(block) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };p },{_,_->saves++;"saved"},{_,_,_->},{})
        try {
            editor.foreground(true);until { editor.state.authorized() };editor.beginPick();editor.picked(Uri.parse("content://test/photo"));until { editor.state.photo!=null && !editor.state.busy }
            editor.changeCrop(AvatarCrop(2f,0.7f,0.5f));val frozen=editor.state.crop.rect(photo.dimensions);editor.save();entered.await()
            editor.changeCrop(AvatarCrop());assertEquals(frozen,observed);editor.foreground(false);release.complete(Unit);delay(50);assertEquals(0,saves)
            block=false;editor.foreground(true);until { editor.state.authorized() };editor.save();until { editor.state.submitted!=null };assertEquals(1,saves);assertNull(editor.state.photo)
        } finally { release.complete(Unit);editor.close() }
    }
    @Test fun uploadCapabilityFailureStillAllowsRemovingAvatarAndExpiredAuthorityDisablesNewPick()=runBlocking {
        var current=access(maximum=null);var saves=0
        val editor=GroupAvatarEditorController("editor",room,this,{current},{image()},{p,_->p},{_,photo->assertNull(photo);saves++;"removed"},{_,_,_->},{})
        try {
            editor.foreground(true);until { editor.state.authorized() };assertFalse(editor.beginPick());editor.save(remove=true);until { saves==1 && !editor.state.busy }
            current=access(deadline=System.nanoTime()+100000000);editor.refresh();until { editor.state.authorized() };delay(150);assertFalse(editor.state.authorized());assertFalse(editor.beginPick())
        } finally { editor.close() }
    }
    @Test fun oldClosedPageCannotPublishACommittedResultIntoNewEditor()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var saved=false;var publications=0
        val editor=GroupAvatarEditorController("editor",room,this,{access()},{image()},{p,_->p},{_,_->entered.complete(Unit);withContext(NonCancellable) { release.await();saved=true };"saved"},{_,_,_->},{publications++})
        try {
            editor.foreground(true);until { editor.state.authorized() };editor.save(true);entered.await();editor.close();val before=publications
            release.complete(Unit);delay(50);assertTrue(saved);assertEquals(before,publications);assertNull(editor.state.submitted)
        } finally { release.complete(Unit);editor.close() }
    }
}
