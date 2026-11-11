package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlin.test.*

class GroupAvatarPageTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val media="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private val data=ByteString.copyFromUtf8("pixels")
    private val content=AvatarContent(media,"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",1,ResourceChecksum("a".repeat(64)),data.size().toLong())
    private fun value(lifetime: Long=60000)=GroupAvatarPresentation(actor,device,GroupAvatarState(room,media,1),1,1,true,AvatarAccess(content,null),
        1000,61000,1000,System.nanoTime()+lifetime*1000000,null)
    private fun fence()=GroupAvatarFence("epoch",0,1,true)
    @Test fun `invalidation clears published bytes and a new visible page reauthorizes`()=runBlocking {
        var reads=0;var denied=false
        val repository=GroupAvatarRepository(actor,device,{ reads++;if(denied) throw ClientFailure.Http(403);value() },{fence()},this)
        val page=GroupAvatarPage(room,repository,{AvatarDownloadedBytes(data,it)},this)
        try {
            withTimeout(5000) { page.state.first { it.image!=null } };assertEquals(1,reads)
            denied=true;repository.invalidate(room)
            withTimeout(5000) { page.state.first { it.unavailable } };assertNull(page.state.value.image)
            page.awaitClosed();assertEquals(0,repository.diagnostics().activations)
        } finally { page.awaitClosed();repository.close() }
    }
    @Test fun `closing clears immediately and waits for physical byte work without publishing its late result`()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val repository=GroupAvatarRepository(actor,device,{value()},{fence()},this)
        val page=GroupAvatarPage(room,repository,{ grant -> entered.complete(Unit);withContext(NonCancellable) { release.await() };AvatarDownloadedBytes(data,grant) },this)
        try {
            entered.await();page.close();assertNull(page.state.value.image)
            val draining=async { page.awaitClosed() };delay(50);assertFalse(draining.isCompleted)
            release.complete(Unit);draining.await();assertNull(page.state.value.image);assertEquals(0,repository.diagnostics().activations)
        } finally { release.complete(Unit);page.awaitClosed();repository.close() }
    }
    @Test fun `expired download target renews authority before retrying bytes`()=runBlocking {
        var reads=0;var downloads=0
        val repository=GroupAvatarRepository(actor,device,{reads++;value()},{fence()},this)
        val page=GroupAvatarPage(room,repository,{ grant -> downloads++;if(downloads==1) throw AvatarTargetExpired();AvatarDownloadedBytes(data,grant) },this)
        try {
            val image=withTimeout(5000) { page.state.first { it.image!=null } }.image!!
            assertEquals(data,image.encoded);assertEquals(2,reads);assertEquals(2,downloads)
        } finally { page.awaitClosed();repository.close() }
    }
    @Test fun `display expiry removes old image while renewed authorization is still pending`()=runBlocking {
        var reads=0;val blocked=CompletableDeferred<Unit>()
        val repository=GroupAvatarRepository(actor,device,{reads++;if(reads>1) blocked.await();value(150)},{fence()},this)
        val page=GroupAvatarPage(room,repository,{AvatarDownloadedBytes(data,it)},this)
        try {
            val old=withTimeout(5000) { page.state.first { it.image!=null } }.image!!
            delay(250);assertFalse(old.valid());assertNull(page.state.value.image);assertEquals(2,reads)
        } finally { blocked.complete(Unit);page.awaitClosed();repository.close() }
    }
    @Test fun `ending account activations clears visible bytes without waiting for display expiry`()=runBlocking {
        val repository=GroupAvatarRepository(actor,device,{value()},{fence()},this)
        val page=GroupAvatarPage(room,repository,{AvatarDownloadedBytes(data,it)},this)
        try {
            withTimeout(5000) { page.state.first { it.image!=null } };repository.endAllActivations()
            withTimeout(5000) { page.state.first { it.image==null } };page.awaitClosed();assertNull(page.state.value.image)
        } finally { page.awaitClosed();repository.close() }
    }
    @Test fun `already cancelled owner never keeps a loading page or activation`()=runBlocking {
        val repository=GroupAvatarRepository(actor,device,{value()},{fence()},this)
        val parent=CoroutineScope(Job().also { it.cancel() }+Dispatchers.Unconfined)
        val page=GroupAvatarPage(room,repository,{AvatarDownloadedBytes(data,it)},parent)
        try { page.awaitClosed();assertTrue(page.isClosed);assertFalse(page.state.value.loading);assertEquals(0,repository.diagnostics().activations) }
        finally { page.awaitClosed();repository.close() }
    }
    @Test fun `oversized display never starts a byte download`()=runBlocking {
        var downloads=0
        val repository=GroupAvatarRepository(actor,device,{value().copy(avatar=AvatarAccess(content.copy(byteCount=8L*1024*1024+1),null))},{fence()},this)
        val page=GroupAvatarPage(room,repository,{downloads++;AvatarDownloadedBytes(data,it)},this)
        try { withTimeout(5000) { page.state.first { it.unavailable } };assertEquals(0,downloads) }
        finally { page.awaitClosed();repository.close() }
    }
}
