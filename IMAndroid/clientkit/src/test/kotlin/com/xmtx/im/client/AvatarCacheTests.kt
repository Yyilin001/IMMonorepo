package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

class AvatarCacheTests {
    @Test fun `warm bytes require current account and display permission but not a live URL`()=runTest {
        val f=AvatarFixture();val scope=f.scope();var calls=0
        val cache=AvatarCache(f.actor,f.device,{ calls++;AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),it) })
        try {
            val grant=scope.avatarReadGrant(f.key)!!;assertContentEquals(f.bytes,cache.read(grant).read().toByteArray())
            f.clock=60_000_000_100;assertFailsWith<AvatarTargetExpired> { grant.downloadTarget() }
            assertContentEquals(f.bytes,cache.read(grant).read().toByteArray());assertEquals(1,calls)
            val borrowed=cache.read(grant);cache.close();assertFailsWith<AvatarAccessFailure> { borrowed.read() }
            val other=AvatarCache(f.target,f.device,{error("must not fetch")})
            try { assertFailsWith<IllegalArgumentException> { other.read(grant) } } finally { other.close() }
            scope.close();assertFailsWith<AvatarAccessFailure> { borrowed.read() };assertEquals(1,calls)
        } finally { scope.close();cache.close() }
    }
    @Test fun `LRU byte budget evicts content without preserving its authorization`()=runTest {
        val f=AvatarFixture();val first=f.scope();val second=f.scope(f.available(f.access().copy(content=f.content.copy(variant=f.actor.value))))
        var calls=0;val cache=AvatarCache(f.actor,f.device,{calls++;AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),it)},maximumBytes=f.bytes.size.toLong(),maximumEntries=2)
        try {
            cache.read(first.avatarReadGrant(f.key)!!);cache.read(second.avatarReadGrant(f.key)!!);cache.read(first.avatarReadGrant(f.key)!!)
            assertEquals(3,calls)
        } finally { first.close();second.close();cache.close() }
    }
    @Test fun `late lower variant cannot overwrite newer observed content`()=runTest {
        val f=AvatarFixture();val old=f.scope();val fresh=f.scope(f.available(f.access().copy(content=f.content.copy(version=2))))
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val cache=AvatarCache(f.actor,f.device,{ grant -> if(grant.content.version==1L) { entered.complete(Unit);release.await() };AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),grant) })
        try {
            val stale=async { runCatching { cache.read(old.avatarReadGrant(f.key)!!) } };entered.await()
            assertEquals(2,cache.read(fresh.avatarReadGrant(f.key)!!).content.version);release.complete(Unit)
            assertIs<AvatarAccessFailure>(stale.await().exceptionOrNull());assertFailsWith<AvatarAccessFailure> { cache.read(old.avatarReadGrant(f.key)!!) }
        } finally { release.complete(Unit);old.close();fresh.close();cache.close() }
    }
    @Test fun `account close cancels and drains physical work and rejects future borrowing`()=runTest {
        val f=AvatarFixture();val scope=f.scope();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val cache=AvatarCache(f.actor,f.device,{ grant -> entered.complete(Unit);withContext(NonCancellable) { release.await() };AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),grant) })
        val reading=launch { cache.read(scope.avatarReadGrant(f.key)!!) };entered.await()
        val closing=async { cache.close() };testScheduler.runCurrent();assertFalse(closing.isCompleted)
        release.complete(Unit);closing.await();assertTrue(reading.isCancelled)
        assertFailsWith<IllegalStateException> { cache.read(scope.avatarReadGrant(f.key)!!) };scope.close()
    }
}
