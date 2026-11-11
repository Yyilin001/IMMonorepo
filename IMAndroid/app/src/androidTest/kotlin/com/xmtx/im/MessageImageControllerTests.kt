package com.xmtx.im

import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class MessageImageControllerTests {
    private val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val message=MessageId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val selection=MessageImageSelection(MediaMessageLocation(room,message),"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private fun frame(token: String="A".repeat(32),original: Boolean=false)=MessageImageFrame(MessageResourceRead(
        ResourceDescriptor(selection.key,1,"image.png","image/png",20,ResourceChecksum("a".repeat(64)),ResourceState.Ready),MessageResourceSource(room,message,0,1),token),ByteString.copyFromUtf8("pixels"),System.nanoTime()+60000000000,original)
    private suspend fun until(test: ()->Boolean)=withTimeout(5000) { while(!test()) delay(10) }
    @Test fun foregroundGenerationAndOriginalRequestsFenceEveryResult()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var token="A".repeat(32);var calls=0
        val controller=MessageImageController(selection,this,changes,{ token },{ calls++;frame(token,it) },{})
        try {
            controller.foreground(true);until { controller.state.frame!=null };assertEquals(1,calls)
            changes.value++;delay(50);assertEquals(1,calls)
            controller.load(true);until { controller.state.frame?.original==true };assertEquals(2,calls)
            token="B".repeat(32);changes.value++;until { controller.state.frame?.read?.generation==token };assertFalse(controller.state.frame!!.original)
            controller.foreground(false);assertNull(controller.state.frame);assertFalse(controller.state.available)
            controller.foreground(true);until { controller.state.frame!=null };assertEquals(4,calls)
        } finally { controller.close() }
    }
    @Test fun uncancellableOldResponseCannotReappearAfterSourceChangeOrPageClose()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var token="A".repeat(32);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var calls=0
        val controller=MessageImageController(selection,this,changes,{ token },{ original ->
            val captured=token;calls++;if(calls==1) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };frame(captured,original)
        },{})
        try {
            controller.foreground(true);entered.await();token="B".repeat(32);changes.value++;until { controller.state.frame?.read?.generation==token }
            release.complete(Unit);delay(50);assertEquals(token,controller.state.frame!!.read.generation)
            controller.close();assertNull(controller.state.frame)
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun failedOriginalKeepsValidPreviewAndExpiryClearsItDuringAnotherRequest()=runBlocking<Unit> {
        val expire=CompletableDeferred<Unit>();var fail=false
        val controller=MessageImageController(selection,this,MutableStateFlow(0L),{ "A".repeat(32) },{ if(fail) error("unavailable");frame(original=it) },{},expiry={ expire.await() })
        try {
            controller.foreground(true);until { controller.state.frame!=null };val preview=controller.state.frame;fail=true
            controller.load(true);until { !controller.state.originalLoading };assertSame(preview,controller.state.frame);assertNotNull(controller.state.feedback)
            expire.complete(Unit);until { controller.state.frame==null };assertTrue(controller.state.feedback!!.contains("过期"))
        } finally { expire.complete(Unit);controller.close() }
    }
    @Test fun deniedOriginalAuthorizationRemovesPreviouslyVisiblePreview()=runBlocking<Unit> {
        val controller=MessageImageController(selection,this,MutableStateFlow(0L),{ "A".repeat(32) },{ if(it) throw MediaReadFailure(MediaReadFailureReason.Denied);frame() },{})
        try {
            controller.foreground(true);until { controller.state.frame!=null };controller.load(true)
            until { !controller.state.originalLoading };assertNull(controller.state.frame);assertTrue(controller.state.feedback!!.contains("权限"))
        } finally { controller.close() }
    }
    @Test fun aDifferentMessageFrameIsRejectedBeforePublicationAndRetryIsExplicit()=runBlocking<Unit> {
        var wrong=true;var calls=0
        val controller=MessageImageController(selection,this,MutableStateFlow(0L),{ "A".repeat(32) },{ calls++;frame().let { if(wrong) it.copy(read=it.read.copy(source=it.read.source.copy(message=MessageId(selection.media)))) else it } },{})
        try {
            controller.foreground(true);until { controller.state.feedback!=null };assertNull(controller.state.frame);assertEquals(1,calls)
            wrong=false;controller.retry();until { controller.state.frame!=null };assertEquals(2,calls)
        } finally { controller.close() }
    }
}
