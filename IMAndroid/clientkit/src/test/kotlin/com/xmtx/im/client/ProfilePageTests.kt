package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ProfilePageTests {
    @Test fun `avatar byte borrowing observes durable authority before UI generation catches up`()=runTest {
        val fixture=AvatarFixture();var generation="first"
        val page=ProfilePresentationPage(fixture.actor,fixture.device,{persistentListOf(fixture.available())},
            { keys -> ProfileFenceSnapshot(generation,keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{fixture.clock})
        page.update(persistentListOf(fixture.key),generation);advanceTimeBy(41);runCurrent()
        val grant=assertNotNull(page.avatarReadGrant(fixture.key));grant.requireValid()
        generation="revoked" // SQLite changes first; UI has not called observeGeneration yet.
        assertFailsWith<AvatarAccessFailure> { grant.requireValid() };assertNull(page.avatarReadGrant(fixture.key))
        page.observeGeneration(generation);advanceTimeBy(41);runCurrent();val renewed=assertNotNull(page.avatarReadGrant(fixture.key))
        renewed.requireValid();page.close();assertFailsWith<AvatarAccessFailure> { renewed.requireValid() }
    }
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val user = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device = DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val key = ProfileKey(user,ProfileContext.Relationship)
    private fun grant(key: ProfileKey = this.key,deadline: Long = 1000000000,revision: Long = 2) = ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(key.user,PublicIdentity(key.user,PublicHandle("friend"),"授权姓名",AccountKind.Regular),null,ProfileState.Active,revision,1),
            ProfileLease(actor,device,key,revision,1,0,ProfileAuthority(1,null,0,0),0,300000)),deadline)

    @Test fun `security invalidation requires strictly newer active profile`() = runTest {
        var result = grant();val scope = ProfilePresentationScope(actor,device,ProfilePresentationReading { persistentListOf(result) },{0})
        scope.interests(persistentListOf(key));scope.fence(key,ProfileFence(securityRevision = 2));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result = grant(revision = 3);scope.refresh();assertEquals("授权姓名",scope.snapshot().profiles.getValue(key).profile.displayName())
        scope.fence(key,ProfileFence(minimumProfileRevision = 4));scope.refresh();assertTrue(scope.snapshot().profiles.isEmpty())
        result = grant(revision = 4);scope.refresh();assertEquals(1,scope.snapshot().profiles.size)
    }
    @Test fun `sync changes during HTTP prevent publication and next generation can read`() = runTest {
        var generation = "one";val gate = CompletableDeferred<Unit>();var calls = 0
        val page = ProfilePresentationPage(actor,device,ProfilePresentationReading { calls++;if(calls == 1) gate.await();persistentListOf(grant(deadline = 100000000000)) },
            { keys -> ProfileFenceSnapshot(generation,keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{testScheduler.currentTime*1000000})
        page.update(persistentListOf(key),generation);advanceTimeBy(41);runCurrent();generation = "two";gate.complete(Unit);runCurrent()
        assertTrue(page.state.value.display.profiles.isEmpty())
        page.observeGeneration(generation);advanceTimeBy(41);runCurrent();assertEquals(1,page.state.value.display.profiles.size)
        page.close();assertTrue(page.state.value.display.profiles.isEmpty())
    }
    @Test fun `all display deadlines expire even while renewal is stalled`() = runTest {
        val other = ProfileKey(UserId(device.value),ProfileContext.Relationship);var calls = 0
        val gate = CompletableDeferred<Unit>()
        val page = ProfilePresentationPage(actor,device,ProfilePresentationReading {
            calls++;if(calls > 1) gate.await();persistentListOf(grant(deadline = 1000000000),grant(other,2000000000))
        },{ keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{testScheduler.currentTime*1000000})
        page.update(persistentListOf(key,other),"one");advanceTimeBy(41);runCurrent();assertEquals(2,page.state.value.display.profiles.size)
        advanceTimeBy(1000);runCurrent();assertTrue(calls >= 2);assertFalse(key in page.state.value.display.profiles)
        advanceTimeBy(1000);runCurrent();assertTrue(page.state.value.display.profiles.isEmpty());page.close()
    }
    @Test fun `closing page or replacing viewport rejects noncooperative old readers`() = runTest {
        val gate = CompletableDeferred<Unit>();var closed = false
        val page = ProfilePresentationPage(actor,device,ProfilePresentationReading { withContext(NonCancellable) { gate.await();persistentListOf(grant()) } },
            { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },backgroundScope,{testScheduler.currentTime*1000000},onClose = { closed = true })
        page.update(persistentListOf(key),"one");advanceTimeBy(41);runCurrent();page.update(persistentListOf(),"one");page.close();gate.complete(Unit);runCurrent()
        assertTrue(closed);assertTrue(page.state.value.display.profiles.isEmpty())
    }
}
