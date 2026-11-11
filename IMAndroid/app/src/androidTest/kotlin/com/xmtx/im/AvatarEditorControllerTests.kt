package com.xmtx.im

import android.graphics.Bitmap
import android.net.Uri
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.PhotoPreparation
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class AvatarEditorControllerTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val baseline=ProfileView(actor,PublicIdentity(actor,PublicHandle("avatar_owner"),"我的资料",AccountKind.Regular),null,ProfileState.Active,1,1)
    private suspend fun photo(color: Int): com.xmtx.im.platform.NormalizedPhoto {
        val bitmap=Bitmap.createBitmap(100,50,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { bitmap.eraseColor(color);assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)) } finally { bitmap.recycle() }
        return PhotoPreparation().prepare(bytes.toByteString())
    }
    private suspend fun until(condition: ()->Boolean) { withTimeout(5000) { while(!condition()) delay(10) } }

    @Test fun pickerReturnWaitsForForegroundAndRotationKeepsOnlyNormalizedEditingState()=runBlocking {
        val image=photo(android.graphics.Color.BLUE);var reads=0
        val editor=AvatarEditorController("editor",actor,this,{ baseline },{ reads++;image },{ p,_->p },{ _,_->"intent" },{},{},{})
        try {
            editor.foreground(true);until { editor.state.baseline!=null };assertTrue(editor.beginPick())
            editor.foreground(false);editor.picked(Uri.parse("content://test/image"));assertEquals(0,reads);assertNull(editor.state.baseline)
            editor.foreground(true);until { editor.state.photo!=null && editor.state.operation==null }
            assertEquals(1,reads);editor.crop(AvatarCrop(2f,0.7f,0.7f));editor.cropOpened()
            val crop=editor.state.crop;editor.foreground(false)
            assertSame(image,editor.state.photo);assertEquals(crop,editor.state.crop);assertNull(editor.state.baseline)
            editor.foreground(true);until { editor.state.baseline!=null };assertEquals(crop,editor.state.crop)
            editor.close();editor.picked(Uri.parse("content://test/late"));assertNull(editor.state.photo)
        } finally { editor.close() }
    }

    @Test fun committedChatImageSelectionReplacesOnlyTemporaryLocalEditingState()=runBlocking {
        val image=photo(android.graphics.Color.BLUE)
        val editor=AvatarEditorController("editor",actor,this,{ baseline },{ image },{ p,_->p },{ _,_->error("chat import uses its own service") },{},{},{})
        try {
            editor.foreground(true);editor.beginPick();editor.picked(Uri.parse("content://test/image"))
            until { editor.state.photo!=null && editor.state.operation==null && editor.state.baseline!=null }
            editor.resourceSubmitted("durable-chat-import")
            assertNull(editor.state.photo);assertNull(editor.state.baseline);assertFalse(editor.state.openCrop)
            assertEquals("durable-chat-import",editor.state.submitted)
        } finally { editor.close() }
    }

    @Test fun lateCancelledImportCannotReplaceTheNextSelection()=runBlocking {
        val first=photo(android.graphics.Color.RED);val second=photo(android.graphics.Color.GREEN)
        val started=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var reads=0
        val editor=AvatarEditorController("editor",actor,this,{ baseline },{
            reads++;if(reads==1) { started.complete(Unit);withContext(NonCancellable) { release.await() };first } else second
        },{ p,_->p },{ _,_->"intent" },{},{},{})
        try {
            editor.foreground(true);assertTrue(editor.beginPick());editor.picked(Uri.parse("content://test/first"));started.await()
            editor.foreground(false);editor.foreground(true);assertTrue(editor.beginPick());editor.picked(Uri.parse("content://test/second"))
            until { editor.state.photo===second };release.complete(Unit);delay(100)
            assertSame(second,editor.state.photo);assertNull(editor.state.operation)
        } finally { release.complete(Unit);editor.close() }
    }

    @Test fun backgroundBeforeCropFinishesPreventsSubmissionAndExplicitSaveFreezesCrop()=runBlocking {
        val image=photo(android.graphics.Color.BLUE);val started=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        var block=true;var submitted=0;var observed: com.xmtx.im.platform.PhotoCrop?=null
        val editor=AvatarEditorController("editor",actor,this,{ baseline },{ image },{ p,crop ->
            observed=crop;if(block) { started.complete(Unit);withContext(NonCancellable) { release.await() } };p
        },{ base,_->assertEquals(baseline,base);submitted++;"original-intent" },{},{},{})
        try {
            editor.foreground(true);editor.beginPick();editor.picked(Uri.parse("content://test/image"));until { editor.state.photo!=null && editor.state.operation==null && editor.state.baseline!=null }
            editor.crop(AvatarCrop(2f,0.7f,0.5f));val expected=editor.state.crop.rect(image.dimensions);editor.save();started.await()
            editor.crop(AvatarCrop());assertEquals(expected,observed)
            editor.foreground(false);release.complete(Unit);delay(100);assertEquals(0,submitted);assertSame(image,editor.state.photo)
            block=false;editor.foreground(true);until { editor.state.baseline!=null };editor.save();until { editor.state.submitted!=null }
            assertEquals(1,submitted);assertEquals("original-intent",editor.state.submitted);assertNull(editor.state.photo)
        } finally { release.complete(Unit);editor.close() }
    }

    @Test fun leavingPageDropsLateSubmissionPresentationWithoutUndoingItsDurableResult()=runBlocking {
        val image=photo(android.graphics.Color.BLUE);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var committed=false;var publications=0
        val editor=AvatarEditorController("old-editor",actor,this,{ baseline },{ image },{ p,_->p },{ _,_->
            entered.complete(Unit);withContext(NonCancellable) { release.await();committed=true };"saved-intent"
        },{},{},{ publications++ })
        try {
            editor.foreground(true);editor.beginPick();editor.picked(Uri.parse("content://test/image"));until { editor.state.photo!=null && editor.state.operation==null && editor.state.baseline!=null }
            editor.save();entered.await();editor.close();val count=publications;release.complete(Unit);delay(100)
            assertTrue(committed);assertEquals(count,publications);assertNull(editor.state.photo);assertNull(editor.state.submitted)
        } finally { release.complete(Unit);editor.close() }
    }
}
