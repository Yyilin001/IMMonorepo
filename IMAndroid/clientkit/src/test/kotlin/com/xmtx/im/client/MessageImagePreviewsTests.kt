package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.security.MessageDigest
import kotlin.test.*

internal class MessagePreviewFixture: MessageResourceReadStore {
    val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");val media="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB";val variantId="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    val bytes=ByteString.copyFromUtf8("verified derived image")
    val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") { "%02x".format(it) })
    val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),1,"图片.png","image/png",500,ResourceChecksum("a".repeat(64)),ResourceState.Ready,100,100)
    var evidence=MessageResourceRead(descriptor,MessageResourceSource(room,MessageId(variantId),0,1),"A".repeat(32))
    var available=true
    override suspend fun resourceReadGeneration()=evidence.generation
    override suspend fun selectMessageResource(key: ResourceKey)=evidence.also { check(available);assertEquals(descriptor.key,key) }
    override suspend fun isMessageResourceCurrent(read: MessageResourceRead)=available && read==evidence
    fun target(url: String="https://provider.invalid/preview?signature=private",version: Long=1,deadline: Long=System.nanoTime()+60000000000): MediaDownloadTarget {
        val preview=ResourceVariantDescriptor(ResourceVariantKey(descriptor.key,ResourceRendition.Derived(variantId,version)),checksum,bytes.size().toLong())
        val plan=ResourceTransferPlan(ResourceTransferMode.Get,url,persistentListOf(ResourceTransferHeader("Authorization","Object capability",ResourceHeaderKind.ObjectCapability)),persistentMapOf(),null,System.currentTimeMillis()+60000,preview.byteCount,null,null,checksum)
        return MediaDownloadTarget(plan,preview,deadline,System::nanoTime)
    }
}
class MessageImagePreviewsTests {
    @Test fun `explicit message cannot borrow another message source`()=runTest {
        val f=MessagePreviewFixture();var authorized=0
        val cache=MessageImagePreviews({ _,_,_->authorized++;f.target() },f,{ f.bytes })
        try {
            val other=MediaMessageLocation(f.room,MessageId(f.media))
            assertEquals(MediaReadFailureReason.SourceChanged,assertFailsWith<MediaReadFailure> { cache.read(f.descriptor.key,message=other) }.reason)
            assertEquals(0,authorized)
            assertEquals(f.bytes,cache.read(f.descriptor.key,message=MediaMessageLocation(f.room,f.evidence.source.message)).encoded)
        } finally { cache.close() }
    }
    @Test fun `cache hits still authorize each message and never substitute original bytes`()=runTest {
        val f=MessagePreviewFixture();var authorizations=0;var transfers=0
        val cache=MessageImagePreviews({ media,message,size ->
            authorizations++;assertEquals(f.media,media);assertEquals(f.room,message!!.room);assertEquals(f.evidence.source.message,message.message);assertEquals(MediaImagePreviewSize.Thumbnail,size);f.target()
        },f,{ transfers++;f.bytes })
        try {
            repeat(2) { val value=cache.read(f.descriptor.key);assertEquals(f.bytes,value.encoded);assertEquals(f.evidence,value.read);assertTrue(value.valid());assertNotEquals(f.descriptor.byteCount,value.variant.byteCount) }
            assertEquals(2,authorizations);assertEquals(1,transfers)
            f.available=false;assertFails { cache.read(f.descriptor.key) };assertEquals(2,authorizations);assertEquals(1,transfers)
        } finally { cache.close() }
    }
    @Test fun `revoke and regrant during transfer never resurrects old evidence`()=runTest {
        val f=MessagePreviewFixture();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val cache=MessageImagePreviews({ _,_,_->f.target() },f,{ entered.complete(Unit);release.await();f.bytes })
        try {
            val pending=async { runCatching { cache.read(f.descriptor.key) } };entered.await()
            f.evidence=f.evidence.copy(generation="B".repeat(32));release.complete(Unit)
            assertEquals(MediaReadFailureReason.SourceChanged,(pending.await().exceptionOrNull() as MediaReadFailure).reason)
        } finally { release.complete(Unit);cache.close() }
    }
    @Test fun `unverified custom transfers and expired targets never enter cache`()=runTest {
        val f=MessagePreviewFixture();var transfers=0;var bad=true;var expired=false
        val cache=MessageImagePreviews({ _,_,_->f.target(deadline=System.nanoTime()+if(expired) -1 else 60000000000) },f,{ transfers++;if(bad) ByteString.copyFromUtf8("wrong") else f.bytes })
        try {
            assertEquals(MediaReadFailureReason.Integrity,assertFailsWith<MediaReadFailure> { cache.read(f.descriptor.key) }.reason)
            bad=false;cache.read(f.descriptor.key);assertEquals(2,transfers)
            expired=true;assertEquals(MediaReadFailureReason.Expired,assertFailsWith<MediaReadFailure> { cache.read(f.descriptor.key) }.reason);assertEquals(2,transfers)
        } finally { cache.close() }
    }
    @Test fun `new variants cannot be downgraded and oversized entries are not retained`()=runTest {
        val f=MessagePreviewFixture();var version=2L;var transfers=0
        val cache=MessageImagePreviews({ _,_,_->f.target(version=version) },f,{ transfers++;f.bytes },maximumBytes=1)
        try {
            cache.read(f.descriptor.key);cache.read(f.descriptor.key);assertEquals(2,transfers)
            version=1;assertEquals(MediaReadFailureReason.Integrity,assertFailsWith<MediaReadFailure> { cache.read(f.descriptor.key) }.reason);assertEquals(2,transfers)
        } finally { cache.close() }
    }
    @Test fun `account close drains physical work and prevents late publication`()=runTest {
        val f=MessagePreviewFixture();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var returned=false
        val cache=MessageImagePreviews({ _,_,_->f.target() },f,{ entered.complete(Unit);withContext(NonCancellable) { release.await() };f.bytes })
        val task=launch { cache.read(f.descriptor.key);returned=true };entered.await()
        val closing=launch { cache.close() };yield();assertFalse(closing.isCompleted);release.complete(Unit);closing.join();task.join()
        assertFalse(returned);assertFailsWith<MediaReadFailure> { cache.read(f.descriptor.key) }
    }
}
