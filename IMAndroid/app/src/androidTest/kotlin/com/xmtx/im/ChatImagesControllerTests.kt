package com.xmtx.im

import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class ChatImagesControllerTests {
    private val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val media="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),1,"image.png","image/png",20,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private fun request(index: Int)=ChatImageRequest(MessageImageSelection(MediaMessageLocation(room,MessageId("CCCCCCCC-CCCC-CCCC-CCCC-%012d".format(index))),media),1,descriptor)
    private fun bytes(request: ChatImageRequest,token: String="A".repeat(32)): MessagePreviewBytes {
        val data=ByteString.copyFromUtf8("pixels")
        return MessagePreviewBytes(MessageResourceRead(request.descriptor,MessageResourceSource(room,request.selection.location.message,0,request.revision),token),
            ResourceVariantDescriptor(ResourceVariantKey(descriptor.key,ResourceRendition.Derived(media,1)),ResourceChecksum("b".repeat(64)),data.size().toLong()),data,System.nanoTime()+60000000000)
    }
    private suspend fun until(test: ()->Boolean)=withTimeout(5000) { while(!test()) delay(10) }
    @Test fun limitsVisibleReadsToTwelveAndConcurrentReadsToTwo()=runBlocking<Unit> {
        val gate=CompletableDeferred<Unit>();var running=0;var maximum=0;var calls=0
        val controller=ChatImagesController(room,this,MutableStateFlow(0L),{ "A".repeat(32) },{ value ->
            calls++;running++;maximum=maxOf(maximum,running)
            try { gate.await();bytes(value) } finally { running-- }
        },{})
        try {
            controller.visible((1..30).map(::request).toPersistentList());controller.foreground(true)
            until { running==2 };delay(50);assertEquals(2,calls)
            gate.complete(Unit);until { controller.state.previews.size==12 };assertEquals(12,calls);assertEquals(2,maximum)
            controller.visible(persistentListOf(request(1)));assertEquals(setOf(request(1)),controller.state.previews.keys)
            controller.visible(persistentListOf());assertTrue(controller.state.previews.isEmpty())
        } finally { gate.complete(Unit);controller.close() }
    }
    @Test fun sameResourceInAnotherMessageOrRevisionCannotSupplyPixels()=runBlocking<Unit> {
        var wrong=true;var calls=0
        val controller=ChatImagesController(room,this,MutableStateFlow(0L),{ "A".repeat(32) },{ value -> calls++;if(wrong) bytes(request(99)) else bytes(value) },{})
        try {
            controller.visible(persistentListOf(request(1),request(2)));controller.foreground(true)
            until { controller.state.failed.size==2 };assertTrue(controller.state.previews.isEmpty());assertEquals(2,calls)
            wrong=false;controller.retry(request(1));until { controller.state.previews.size==1 };assertEquals(request(1).selection.location.message,controller.state.previews[request(1)]!!.read.source.message)
            val revised=request(1).copy(revision=2);controller.visible(persistentListOf(revised));until { controller.state.previews[revised]!=null }
            assertEquals(2,controller.state.previews[revised]!!.read.source.revision)
        } finally { controller.close() }
    }
    @Test fun sourceGenerationBackgroundAndExpiryRemoveRetainedBytes()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var token="A".repeat(32);var calls=0;var deadline=CompletableDeferred<Unit>()
        val controller=ChatImagesController(room,this,changes,{ token },{ calls++;bytes(it,token) },{},expiry={ deadline.await() })
        try {
            controller.visible(persistentListOf(request(1)));controller.foreground(true);until { controller.state.previews.size==1 }
            changes.value++;delay(50);assertEquals(1,calls)
            token="B".repeat(32);changes.value++;until { controller.state.previews[request(1)]?.read?.generation==token };assertEquals(2,calls)
            deadline.complete(Unit);until { request(1) in controller.state.failed };assertTrue(controller.state.previews.isEmpty())
            changes.value++;delay(50);assertEquals(2,calls)
            deadline=CompletableDeferred();controller.retry(request(1));until { controller.state.previews.size==1 }
            controller.foreground(false);assertTrue(controller.state.previews.isEmpty());assertFalse(controller.state.available)
            controller.foreground(true);until { controller.state.previews.size==1 };assertEquals(4,calls)
        } finally { deadline.complete(Unit);controller.close() }
    }
    @Test fun nonCancellableReadCannotRestoreOffscreenOrOldGenerationPixels()=runBlocking<Unit> {
        val release=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();var calls=0;var token="A".repeat(32);val changes=MutableStateFlow(0L)
        val controller=ChatImagesController(room,this,changes,{ token },{ value ->
            val saved=token;calls++;if(calls==1) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };bytes(value,saved)
        },{})
        try {
            controller.visible(persistentListOf(request(1)));controller.foreground(true);entered.await()
            controller.visible(persistentListOf());controller.visible(persistentListOf(request(1)))
            token="B".repeat(32);changes.value++;until { controller.state.previews[request(1)]?.read?.generation==token }
            release.complete(Unit);delay(50);assertEquals(token,controller.state.previews[request(1)]!!.read.generation)
            controller.close();assertTrue(controller.state.previews.isEmpty())
        } finally { release.complete(Unit);controller.close() }
    }
    @Test fun generationFailureClearsPixelsAndExplicitRetryRestartsObservation()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var failed=false
        val controller=ChatImagesController(room,this,changes,{ if(failed) error("store unavailable");"A".repeat(32) },{ bytes(it) },{})
        try {
            controller.visible(persistentListOf(request(1)));controller.foreground(true);until { controller.state.previews.size==1 }
            failed=true;changes.value++;until { request(1) in controller.state.failed };assertTrue(controller.state.previews.isEmpty())
            controller.visible(persistentListOf(request(2)));assertTrue(request(2) in controller.state.failed)
            failed=false;controller.retry(request(2));until { controller.state.previews.size==1 }
        } finally { controller.close() }
    }
}
