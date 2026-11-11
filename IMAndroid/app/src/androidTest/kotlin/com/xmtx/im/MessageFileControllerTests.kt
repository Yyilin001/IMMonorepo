package com.xmtx.im

import android.net.Uri
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

internal fun fileTestSelection()=MessageFileSelection(MediaMessageLocation(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),MessageId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
internal fun fileTestRead(selection: MessageFileSelection=fileTestSelection())=MessageResourceRead(
    ResourceDescriptor(selection.key,1,"项目说明.txt","text/plain",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready),MessageResourceSource(selection.location.room,selection.location.message,0,1),"A".repeat(32))
class MessageFileControllerTests {
    private val selection=fileTestSelection();private val uri=Uri.parse("content://test/export")
    private suspend fun until(predicate: ()->Boolean)=withTimeout(5000) { while(!predicate()) delay(10) }
    @Test fun pickerReturnsWhileBackgroundedThenFreshSourceIsVerifiedBeforeWriting()=runBlocking<Unit> {
        var saves=0;var discards=0;val read=fileTestRead()
        val controller=MessageFileController(selection,this,MutableStateFlow(0L),{read},{request,destination->assertEquals(read,request.read);assertEquals(uri,destination);saves++},{discards++;true},{})
        try {
            controller.foreground(true);until { controller.state.available };val id=controller.begin()!!;assertNull(controller.begin())
            controller.foreground(false);controller.result(id,uri);delay(50);assertEquals(0,saves);assertEquals(FileSavePhase.Waiting,controller.state.phase)
            controller.foreground(true);until { controller.state.phase==FileSavePhase.Saved };assertEquals(1,saves);assertEquals(0,discards);assertEquals(uri.toString(),controller.state.savedUri)
        } finally { controller.close();controller.awaitClosed() }
    }
    @Test fun sourceChangesDuringPickerCannotExportUnderNewAuthority()=runBlocking<Unit> {
        var read=fileTestRead();var saves=0;var discards=0
        val controller=MessageFileController(selection,this,MutableStateFlow(0L),{read},{_,_->saves++},{discards++;true},{})
        try {
            controller.foreground(true);until { controller.state.available };val id=controller.begin()!!;controller.foreground(false)
            controller.result(id,uri);read=read.copy(generation="B".repeat(32));controller.foreground(true)
            until { discards==1 };assertEquals(0,saves);assertNull(controller.state.savedUri)
        } finally { controller.close();controller.awaitClosed() }
    }
    @Test fun backgroundCancellationDrainsWritingAndDiscardsLateSuccess()=runBlocking<Unit> {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var discarded=false
        val controller=MessageFileController(selection,this,MutableStateFlow(0L),{fileTestRead()},{_,_->entered.complete(Unit);withContext(NonCancellable) { release.await() }},{discarded=true;true},{})
        try {
            controller.foreground(true);until { controller.state.available };controller.result(controller.begin()!!,uri);entered.await()
            controller.foreground(false);assertNull(controller.begin());controller.close();val drain=async { controller.awaitClosed() };delay(30);assertFalse(drain.isCompleted)
            release.complete(Unit);drain.await();assertTrue(discarded);assertNull(controller.state.savedUri)
        } finally { release.complete(Unit);controller.close();controller.awaitClosed() }
    }
    @Test fun failedWriteReportsUnremovablePartialAndCanRetry()=runBlocking<Unit> {
        var fail=true;val controller=MessageFileController(selection,this,MutableStateFlow(0L),{fileTestRead()},{_,_->if(fail) error("provider failed")},{false},{})
        try {
            controller.foreground(true);until { controller.state.available };controller.result(controller.begin()!!,uri);until { controller.state.feedback?.contains("手动删除")==true }
            fail=false;val next=controller.begin()!!;controller.result(next,uri);until { controller.state.phase==FileSavePhase.Saved };assertEquals(uri.toString(),controller.state.savedUri)
        } finally { controller.close();controller.awaitClosed() }
    }
    @Test fun wrongMessageMetadataAndStalePickerCallbacksCannotWrite()=runBlocking<Unit> {
        var wrong=true;var calls=0
        val controller=MessageFileController(selection,this,MutableStateFlow(0L),{fileTestRead().let { if(wrong) it.copy(source=it.source.copy(message=MessageId(selection.media))) else it }},{_,_->calls++},{true},{})
        try {
            controller.foreground(true);until { controller.state.feedback!=null };assertNull(controller.begin())
            wrong=false;controller.retry();until { controller.state.available };val old=controller.begin()!!;controller.pickerFailed(old);val current=controller.begin()!!
            controller.result(old,uri);assertEquals(0,calls);assertTrue(controller.accepts(current));controller.result(current,null);assertEquals(FileSavePhase.Idle,controller.state.phase)
        } finally { controller.close();controller.awaitClosed() }
    }
    @Test fun revocationDuringWriteCancelsAndCleansTheDestination()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var available=true;var discarded=false;val entered=CompletableDeferred<Unit>()
        val controller=MessageFileController(selection,this,changes,{check(available);fileTestRead()},{_,_->entered.complete(Unit);awaitCancellation()},{discarded=true;true},{})
        try {
            controller.foreground(true);until { controller.state.available };controller.result(controller.begin()!!,uri);entered.await()
            available=false;changes.value++;until { discarded };assertFalse(controller.state.available);assertNull(controller.state.savedUri)
        } finally { controller.close();controller.awaitClosed() }
    }
}
