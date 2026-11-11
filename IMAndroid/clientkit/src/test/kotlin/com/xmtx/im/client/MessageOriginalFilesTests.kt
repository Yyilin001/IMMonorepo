package com.xmtx.im.client

import kotlinx.coroutines.*
import java.io.File
import kotlin.test.*

class MessageOriginalFilesTests {
    private class Fixture: MessageResourceReadStore {
        val preview=MessagePreviewFixture()
        var read=preview.evidence.copy(descriptor=preview.descriptor.copy(byteCount=preview.bytes.size().toLong(),checksum=preview.checksum))
        var observed=0
        override suspend fun observeResourceVariant(read:MessageResourceRead,target:MediaDownloadTarget) {assertEquals(this.read,read);assertTrue(isMessageResourceCurrent(read));observed++}
        var available=true;var authorizations=0;var borrows=0;var cached=true
        var beforeBorrow: suspend ()->Unit={};var duringAuthorization: suspend ()->Unit={}
        var bad=false;var expired=false
        override suspend fun resourceReadGeneration()=read.generation
        override suspend fun selectMessageResource(key: ResourceKey)=read.also { check(available) }
        override suspend fun isMessageResourceCurrent(read: MessageResourceRead)=available && read==this.read
        val files=object: ResourceDownloadFiles {
            override suspend fun <T> withDownloaded(target: MediaDownloadTarget,cacheOnly: Boolean,block: suspend (File)->T): T? {
                borrows++;beforeBorrow();if(cacheOnly && !cached) return null;return block(File("unused-test-file"))
            }
        }
        val service=MessageOriginalFiles({ media,location,size ->
            authorizations++;assertEquals(read.descriptor.key.media,media);assertEquals(read.source.message,location!!.message);assertNull(size)
            duringAuthorization()
            MediaDownloadTarget(preview.target().plan.copy(expectedBytes=preview.bytes.size().toLong()+if(bad) 1 else 0),null,System.nanoTime()+if(expired) -1 else 60000000000,System::nanoTime)
        },this,files)
    }
    @Test fun `explicit original context preserves the clicked message and exposes only its read deadline`()=runBlocking<Unit> {
        val f=Fixture()
        try {
            assertFailsWith<MediaReadFailure> { f.service.withOriginal(f.read.descriptor.key,message=MediaMessageLocation(f.read.source.room,MessageId(f.read.descriptor.key.media))) { _,_->Unit } }
            assertEquals(0,f.authorizations)
            f.service.withAuthorizedOriginal(f.read.descriptor.key,message=MediaMessageLocation(f.read.source.room,f.read.source.message)) { authorized,_->
                assertEquals(f.read,authorized.evidence);assertTrue(authorized.deadlineNanos>System.nanoTime())
            }
            assertEquals(1,f.authorizations)
        } finally { f.service.close() }
    }
    @Test fun `every borrow including cached misses obtains independent message authorization`()=runBlocking<Unit> {
        val f=Fixture()
        try {
            repeat(2) { assertEquals("decoded",f.service.withOriginal(f.read.descriptor.key,true) { read,_->assertEquals(f.read,read);"decoded" }) }
            f.cached=false;assertNull(f.service.withOriginal(f.read.descriptor.key,true) { _,_->error("cache miss") })
            assertEquals(3,f.authorizations);assertEquals(3,f.borrows);assertEquals(3,f.observed)
            f.available=false;assertFails { f.service.withOriginal(f.read.descriptor.key) { _,_->Unit } };assertEquals(3,f.authorizations)
        } finally { f.service.close() }
    }
    @Test fun `target mismatch expiry and authorization generation races never borrow bytes`()=runBlocking<Unit> {
        for(mode in 0..2) {
            val f=Fixture()
            try {
                when(mode) { 0->f.bad=true;1->f.expired=true;else->f.duringAuthorization={ f.read=f.read.copy(generation="B".repeat(32)) } }
                assertFailsWith<MediaReadFailure> { f.service.withOriginal(f.read.descriptor.key) { _,_->error("forbidden borrow") } };assertEquals(0,f.borrows);assertEquals(0,f.observed)
            } finally { f.service.close() }
        }
    }
    @Test fun `source revocation before callback and during decoding fences results`()=runBlocking<Unit> {
        val f=Fixture()
        try {
            f.beforeBorrow={ f.available=false }
            assertEquals(MediaReadFailureReason.SourceChanged,assertFailsWith<MediaReadFailure> { f.service.withOriginal(f.read.descriptor.key) { _,_->error("stale bytes") } }.reason)
            f.available=true;f.beforeBorrow={}
            assertEquals(MediaReadFailureReason.SourceChanged,assertFailsWith<MediaReadFailure> { f.service.withOriginal(f.read.descriptor.key) { _,_->f.read=f.read.copy(generation="B".repeat(32));"stale decode" } }.reason)
        } finally { f.service.close() }
    }
    @Test fun `account close cancels borrowers and waits for physical callback drain`()=runBlocking<Unit> {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var returned=false
        val reader=launch { f.service.withOriginal(f.read.descriptor.key) { _,_->entered.complete(Unit);withContext(NonCancellable) { release.await() };"decoded" };returned=true }
        entered.await();val closing=launch { f.service.close() };yield();assertFalse(closing.isCompleted)
        release.complete(Unit);withTimeout(5000) { reader.join();closing.join() };assertFalse(returned)
        assertFailsWith<MediaReadFailure> { f.service.withOriginal(f.read.descriptor.key) { _,_->Unit } }
    }
}
