package com.xmtx.im

import android.graphics.Bitmap
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.NormalizedPhoto
import com.xmtx.im.platform.PhotoPreparation
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

internal suspend fun draftImageTestPhoto(): NormalizedPhoto {
    val bitmap=Bitmap.createBitmap(320,200,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
    try {
        val canvas=android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(120,190,220));val paint=android.graphics.Paint().apply { color=android.graphics.Color.rgb(25,120,160) }
        canvas.drawRect(0f,110f,320f,200f,paint);paint.color=android.graphics.Color.rgb(255,220,100);canvas.drawCircle(250f,45f,25f,paint)
        bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)
    } finally { bitmap.recycle() }
    return PhotoPreparation().prepare(bytes.toByteString())
}
class DraftImageControllerTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val selection=DraftImageSelection(RoomId(id()),id())
    private fun source()=SendAttachment(id(),selection.asset,"海边.jpg","image/jpeg",1200)
    private suspend fun until(test: ()->Boolean)=withTimeout(5000) { while(!test()) delay(10) }
    @Test fun backgroundClearsPixelsAndCloseDrainsAnUncancellableRead()=runBlocking<Unit> {
        val source=source();val image=draftImageTestPhoto();val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>()
        val controller=DraftImageController(selection,this,MutableStateFlow(0L),{source},{ entered.complete(Unit);withContext(NonCancellable) { gate.await() };image },{})
        try {
            controller.foreground(true);entered.await();controller.foreground(false);assertNull(controller.state.photo)
            val closing=launch { controller.close() };delay(30);assertFalse(closing.isCompleted);gate.complete(Unit);closing.join();assertNull(controller.state.photo)
        } finally { gate.complete(Unit);controller.close() }
    }
    @Test fun removalInvalidatesTheReadBeforeALateResultReturns()=runBlocking<Unit> {
        var current:SendAttachment?=source();val image=draftImageTestPhoto();val changes=MutableStateFlow(0L);val gate=CompletableDeferred<Unit>();var reading=false
        val controller=DraftImageController(selection,this,changes,{current},{ reading=true;withContext(NonCancellable) { gate.await() };image },{})
        try {
            controller.foreground(true);until { reading };current=null;changes.value++;until { controller.state.attachment==null }
            gate.complete(Unit);controller.close();assertNull(controller.state.photo)
        } finally { gate.complete(Unit);controller.close() }
    }
    @Test fun unchangedSelectionDoesNotRedecodeAndForegroundRetryResolvesAgain()=runBlocking<Unit> {
        val source=source();val image=draftImageTestPhoto();val changes=MutableStateFlow(0L);var reads=0;var resolutions=0
        val controller=DraftImageController(selection,this,changes,{ resolutions++;source },{ reads++;image },{})
        try {
            controller.foreground(true);until { controller.state.photo!=null };val before=resolutions;changes.value++
            until { resolutions>before };assertEquals(1,reads);controller.foreground(false);assertNull(controller.state.photo)
            controller.foreground(true);until { reads==2 && controller.state.photo!=null };assertSame(image,controller.state.photo)
        } finally { controller.close() }
    }
    @Test fun wrongAssetIsRejectedAndRetryCanRecoverTheCorrectSource()=runBlocking<Unit> {
        var current=source().copy(asset=id());val image=draftImageTestPhoto();var reads=0
        val controller=DraftImageController(selection,this,MutableStateFlow(0L),{current},{ reads++;image },{})
        try {
            controller.foreground(true);until { controller.state.feedback!=null };assertEquals(0,reads);assertNull(controller.state.photo)
            current=source();controller.retry();until { controller.state.photo!=null };assertEquals(1,reads)
        } finally { controller.close() }
    }
}
