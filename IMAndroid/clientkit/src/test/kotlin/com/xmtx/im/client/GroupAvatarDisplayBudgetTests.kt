package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlin.test.*

class GroupAvatarDisplayBudgetTests {
    @Test fun `queued large display is not overtaken and cancelling it admits the next visible row`()=runBlocking {
        val budget=GroupAvatarDisplayBudget(10);val a=Any();val b=Any();val large=Any();val small=Any()
        budget.acquire(a,6);budget.acquire(b,4)
        val first=async(start=CoroutineStart.UNDISPATCHED) { budget.acquire(large,8) }
        val next=async(start=CoroutineStart.UNDISPATCHED) { budget.acquire(small,2) }
        assertEquals(2,budget.diagnostics().waiting);budget.release(a);yield();assertFalse(first.isCompleted);assertFalse(next.isCompleted)
        first.cancelAndJoin();next.await();assertEquals(6,budget.diagnostics().bytes);assertEquals(0,budget.diagnostics().waiting)
        budget.release(small);budget.release(b);assertEquals(GroupAvatarDisplayBudget.Diagnostics(0,0,0),budget.diagnostics())
    }
    @Test fun `cancelled admission and invalid repeat acquisition preserve other reservations`()=runBlocking {
        val budget=GroupAvatarDisplayBudget(10);val owner=Any();val waiting=Any()
        budget.acquire(owner,10);assertFailsWith<IllegalStateException> { budget.acquire(owner,1) }
        assertEquals(10,budget.diagnostics().bytes)
        val job=launch(start=CoroutineStart.UNDISPATCHED) { budget.acquire(waiting,1) };job.cancelAndJoin();budget.release(owner)
        assertEquals(GroupAvatarDisplayBudget.Diagnostics(0,0,0),budget.diagnostics())
        assertFailsWith<IllegalArgumentException> { budget.acquire(owner,11) };assertEquals(0,budget.diagnostics().bytes)
    }
    @Test fun `leaving a row clears pixels but physical download keeps budget until drained`()=runBlocking {
        val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        val roomA=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");val roomB=RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
        val data=ByteString.copyFromUtf8("pixels");val content=AvatarContent("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",1,ResourceChecksum("a".repeat(64)),6)
        val repository=GroupAvatarRepository(actor,device,{ room -> GroupAvatarPresentation(actor,device,GroupAvatarState(room,content.media,1),1,1,true,AvatarAccess(content,null),1000,61000,1000,System.nanoTime()+60000000000,null) },{GroupAvatarFence("epoch",0,1,true)},this)
        val budget=GroupAvatarDisplayBudget(6);val started=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var secondDownloads=0
        val first=GroupAvatarPage(roomA,repository,{ grant -> started.complete(Unit);withContext(NonCancellable) { release.await() };AvatarDownloadedBytes(data,grant) },this,budget=budget)
        var second:GroupAvatarPage?=null
        try {
            started.await();second=GroupAvatarPage(roomB,repository,{ grant -> secondDownloads++;AvatarDownloadedBytes(data,grant) },this,budget=budget)
            withTimeout(5000) { while(budget.diagnostics().waiting!=1) delay(5) }
            first.close();delay(50);assertEquals(0,secondDownloads);assertEquals(6,budget.diagnostics().bytes);assertNull(first.state.value.image)
            release.complete(Unit);first.awaitClosed();withTimeout(5000) { second.state.first { it.image!=null } }
            assertEquals(1,secondDownloads);assertEquals(6,budget.diagnostics().bytes)
            second.awaitClosed();assertEquals(0,budget.diagnostics().bytes)
        } finally { release.complete(Unit);first.awaitClosed();second?.awaitClosed();repository.close() }
    }
}
