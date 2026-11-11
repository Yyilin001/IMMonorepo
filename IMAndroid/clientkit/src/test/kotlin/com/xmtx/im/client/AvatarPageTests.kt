package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AvatarPageTests {
    @Test fun `visible avatar admission bounds total encoded bytes before starting downloads`()=runTest {
        val f=AvatarFixture();val data=ByteString.copyFrom(ByteArray(2*1024*1024));val content=f.content.copy(byteCount=data.size().toLong())
        val keys=(1..40).map { ProfileKey(UserId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}"),ProfileContext.Relationship) }.toPersistentList()
        var downloads=0
        val page=ProfilePresentationPage(f.actor,f.device,{ requested -> requested.map { key ->
            val original=f.available();original.copy(profile=original.profile.copy(view=original.profile.view.copy(user=key.user,identity=original.profile.view.identity!!.copy(user=key.user)),lease=original.profile.lease.copy(key=key)),
                avatar=AvatarAccess(content,null),avatarDownloadDeadlineNanos=null)
        }.toPersistentList() },{ requested -> ProfileFenceSnapshot("one",requested.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{f.clock},
            avatarReader={ downloads++;AvatarDownloadedBytes(data,it) })
        page.update(keys,"one",keys);advanceTimeBy(41);runCurrent()
        assertEquals(4,downloads);assertEquals(8L*1024*1024,page.state.value.display.avatars.values.sumOf { it.encoded.size().toLong() });page.close()
    }
    @Test fun `avatar expiry and page generation clear pixels independently from cached bytes`()=runTest {
        val f=AvatarFixture();var generation="one"
        val page=ProfilePresentationPage(f.actor,f.device,{persistentListOf(f.available(deadline=1_000_000_000,download=500_000_000))},
            { keys -> ProfileFenceSnapshot(generation,keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{testScheduler.currentTime*1_000_000},
            avatarReader={AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),it)})
        page.update(persistentListOf(f.key),generation,persistentListOf(f.key));advanceTimeBy(41);runCurrent()
        assertEquals(1,page.state.value.display.avatars.size);generation="two";page.observeGeneration(generation)
        assertTrue(page.state.value.display.avatars.isEmpty());advanceTimeBy(41);runCurrent();assertEquals(1,page.state.value.display.avatars.size)
        advanceTimeBy(1000);runCurrent();assertTrue(page.state.value.display.avatars.isEmpty());page.close()
    }
    @Test fun `expired URL renews the shared batch while authorized name stays visible`()=runTest {
        val f=AvatarFixture();var reads=0;var downloads=0
        val page=ProfilePresentationPage(f.actor,f.device,{reads++;persistentListOf(f.available())},
            { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{f.clock},
            avatarReader={ downloads++;if(downloads==1) throw AvatarTargetExpired();AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),it) })
        page.update(persistentListOf(f.key),"one",persistentListOf(f.key));advanceTimeBy(41);runCurrent()
        assertEquals(1,reads);assertEquals("好友 B",page.state.value.display.profiles[f.key]!!.profile.displayName());assertTrue(page.state.value.display.avatars.isEmpty())
        advanceTimeBy(3001);runCurrent();assertEquals(2,reads);assertEquals(2,downloads);assertEquals(1,page.state.value.display.avatars.size);page.close()
    }
    @Test fun `old uncooperative download cannot replace new page content or reappear after close`()=runTest {
        val f=AvatarFixture();var current=f.available();var generation="one";val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val page=ProfilePresentationPage(f.actor,f.device,{persistentListOf(current)},
            { keys -> ProfileFenceSnapshot(generation,keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{f.clock},
            avatarReader={ grant -> if(grant.content.version==1L) { entered.complete(Unit);withContext(NonCancellable) { release.await() } };AvatarDownloadedBytes(ByteString.copyFrom(f.bytes),grant) })
        page.update(persistentListOf(f.key),generation,persistentListOf(f.key));advanceTimeBy(41);runCurrent();entered.await()
        current=f.available(f.access().copy(content=f.content.copy(version=2)));generation="two";page.observeGeneration(generation);advanceTimeBy(41);runCurrent()
        assertEquals(2,page.state.value.display.avatars[f.key]!!.content.version);release.complete(Unit);runCurrent()
        assertEquals(2,page.state.value.display.avatars[f.key]!!.content.version);page.close();runCurrent();assertTrue(page.state.value.display.avatars.isEmpty())
    }
    @Test fun `name-only interests never trigger avatar network work`()=runTest {
        val f=AvatarFixture();val page=ProfilePresentationPage(f.actor,f.device,{persistentListOf(f.available())},
            { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{f.clock},avatarReader={error("unexpected avatar request")})
        page.update(persistentListOf(f.key),"one");advanceTimeBy(41);runCurrent();assertEquals(1,page.state.value.display.profiles.size);assertTrue(page.state.value.display.avatars.isEmpty());page.close()
    }
}
