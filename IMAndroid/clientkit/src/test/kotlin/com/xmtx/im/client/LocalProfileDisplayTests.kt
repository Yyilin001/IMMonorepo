package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class LocalProfileDisplayTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val user = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device = DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val room = RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private val key = ProfileKey(user, ProfileContext.Relationship)
    private fun available(key: ProfileKey = this.key, revision: Long = 1, alias: ProfileAlias? = null,
        group: ProfileGroupName? = null, deadline: Long = 100_000_000_000): ProfileReadResult.Available {
        val scoped = (key.context as? ProfileContext.Room)?.room
        return ProfileReadResult.Available(AuthorizedProfile(ProfileView(user,
            PublicIdentity(user, PublicHandle("friend"), "姓名$revision", AccountKind.Regular), null, ProfileState.Active, revision, revision),
            ProfileLease(actor, device, key, revision, revision, if (scoped == null) 0 else 1,
                ProfileAuthority(revision, scoped, if (scoped == null) 0 else 1, 0), revision, revision + 60_000), group, alias), deadline)
    }
    @Test fun `remarks cross contacts while nicknames and remark permission stay room scoped`() {
        val groupKey = ProfileKey(user, ProfileContext.Room(room))
        val contact = LocalProfileDisplay.from(available(alias = ProfileAlias(actor, user, "我的备注", 3)).profile)!!
        val group = LocalProfileDisplay.from(available(groupKey, group = ProfileGroupName(room, user, "群昵称", 2)).profile)!!
        val basic = LocalProfileBasics.merge(contact, LocalProfileBasics.merge(group))
        val snapshot = LocalProfileDisplaySnapshot(persistentMapOf(key to contact, groupKey to group), persistentMapOf(user to basic))
        assertEquals("我的备注", snapshot.value(ProfileKey(user, ProfileContext.DirectConversation))?.name)
        assertEquals("群昵称", snapshot.value(groupKey)?.name)
        assertEquals("姓名1", snapshot.value(ProfileKey(user, ProfileContext.GroupJoinReview(room)))?.name)
        assertEquals("我的备注", snapshot.copy(records = snapshot.records.put(groupKey, group.copy(alias = contact.alias))).value(groupKey)?.name)
        assertNull(snapshot.copy(deniedKeys = persistentSetOf(groupKey)).value(groupKey))
        assertEquals("我的备注", snapshot.copy(deniedKeys = persistentSetOf(groupKey)).value(key)?.name)
        assertNull(snapshot.copy(deniedUsers = persistentSetOf(user)).value(key))
    }
    @Test fun `independent counters cannot roll identity or remarks backwards including explicit removal`() {
        val first = LocalProfileDisplay.from(available(revision = 4, alias = ProfileAlias(actor, user, "新备注", 7)).profile)!!
        val old = LocalProfileDisplay.from(available(revision = 2, alias = ProfileAlias(actor, user, "旧备注", 3)).profile)!!
        assertFalse(old.supersedes(first))
        val basics = LocalProfileBasics.merge(old, LocalProfileBasics.merge(first))
        assertEquals("姓名4", basics.identity.displayName); assertEquals("新备注", basics.alias?.name)
        val removed = first.copy(alias = ProfileAlias(actor, user, null, 8))
        assertNull(LocalProfileBasics.merge(removed, basics).alias?.name)
        assertEquals(8, LocalProfileBasics.merge(old, LocalProfileBasics.merge(removed, basics)).alias?.revision)
    }
    @Test fun `accepted facts persist before page publication and expiry does not write a denial`() = runTest {
        val gate = CompletableDeferred<Unit>(); val saved = mutableListOf<PersistentList<ProfileReadResult>>()
        val page = ProfilePresentationPage(actor, device, { persistentListOf(available(deadline = 100_000_000)) },
            { ProfileFenceSnapshot("one", it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { testScheduler.currentTime * 1_000_000 }, localDisplays = LocalProfileDisplaySaving { values, _ ->
                saved.add(values); gate.await(); true
            })
        page.update(persistentListOf(key), "one"); advanceTimeBy(41); runCurrent()
        assertEquals(1, saved.size); assertTrue(page.state.value.display.profiles.isEmpty())
        gate.complete(Unit); runCurrent(); assertEquals(1, page.state.value.display.profiles.size)
        advanceTimeBy(100); runCurrent(); assertTrue(page.state.value.display.profiles.isEmpty())
        assertTrue(saved.flatten().all { it is ProfileReadResult.Available }); page.close()
    }
    @Test fun `stale generation and rejected journal never publish or persist an unchecked response`() = runTest {
        var generation = "one"; val response = CompletableDeferred<Unit>(); var writes = 0
        val page = ProfilePresentationPage(actor, device, { response.await(); persistentListOf(available()) },
            { ProfileFenceSnapshot(generation, it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { 0 }, localDisplays = LocalProfileDisplaySaving { _, _ -> writes++; false })
        page.update(persistentListOf(key), generation); advanceTimeBy(41); runCurrent()
        generation = "two"; response.complete(Unit); runCurrent()
        assertEquals(0, writes); assertTrue(page.state.value.display.profiles.isEmpty())
        page.observeGeneration(generation); advanceTimeBy(41); runCurrent()
        assertEquals(1, writes); assertTrue(page.state.value.display.profiles.isEmpty()); page.close()
    }
    @Test fun `page retirement during noncooperative journal cannot republish`() = runTest {
        val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
        val page = ProfilePresentationPage(actor, device, { persistentListOf(available()) },
            { ProfileFenceSnapshot("one", it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { 0 }, localDisplays = LocalProfileDisplaySaving { _, _ -> withContext(NonCancellable) {
                entered.complete(Unit); finish.await(); true
            } })
        page.update(persistentListOf(key), "one"); advanceTimeBy(41); runCurrent(); assertTrue(entered.isCompleted)
        page.close(); finish.complete(Unit); runCurrent(); assertEquals(ProfilePageSnapshot(), page.state.value)
    }
    @Test fun `author acceptance journals before publishing or acknowledging and retry is never a denial`() = runTest {
        var now = 0L; val saved = mutableListOf<PersistentList<ProfileReadResult>>()
        val page = ProfilePresentationPage(actor, device, { persistentListOf(ProfileReadResult.Retryable(key)) },
            { ProfileFenceSnapshot("one", it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { now }, localDisplays = LocalProfileDisplaySaving { values, _ -> saved.add(values); true })
        page.update(persistentListOf(key), "one"); advanceTimeBy(41); runCurrent(); assertTrue(saved.isEmpty())
        now = 1
        val receiver = AuthorPresentationReceiver(actor, device, { now })
        val view = receiver.begin("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", persistentListOf()); page.bindAuthor(view)
        val delta = ReceivedAuthorPresentationDelta(view, 1, persistentListOf(ReceivedAuthorPresentationEntry.Available(available())))
        page.ingestAuthor(delta)
        assertEquals(1, saved.size); assertEquals(1, page.retainedAuthor(delta).size)
        assertEquals(1, page.state.value.display.profiles.size)
        val denied = ReceivedAuthorPresentationDelta(view, 2, persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(
            ProfileReadResult.Unavailable(key, ProfileAuthority(2, null, 0, 0)), 10_000_000_000)))
        page.ingestAuthor(denied); assertIs<ProfileReadResult.Unavailable>(saved.last().single())
        assertTrue(key in page.state.value.display.unavailable); page.close(); receiver.close()
    }
    @Test fun `old expiry callback cannot publish a new author result while its journal is suspended`() = runTest {
        val gate = CompletableDeferred<Unit>(); var writes = 0
        val page = ProfilePresentationPage(actor, device, { persistentListOf(available(deadline = 100_000_000)) },
            { ProfileFenceSnapshot("one", it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { testScheduler.currentTime * 1_000_000 }, localDisplays = LocalProfileDisplaySaving { _, _ ->
                if (++writes == 2) gate.await(); true
            })
        page.update(persistentListOf(key), "one"); advanceTimeBy(50); runCurrent()
        assertEquals("姓名1", page.state.value.display.profiles[key]?.profile?.displayName())
        val receiver = AuthorPresentationReceiver(actor, device, { testScheduler.currentTime * 1_000_000 })
        val view = receiver.begin("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", persistentListOf()); page.bindAuthor(view)
        val incoming = async { page.ingestAuthor(ReceivedAuthorPresentationDelta(view, 1,
            persistentListOf(ReceivedAuthorPresentationEntry.Available(available(revision = 2))))) }
        runCurrent(); assertEquals(2, writes)
        advanceTimeBy(100); runCurrent(); assertTrue(page.state.value.display.profiles.isEmpty())
        gate.complete(Unit); incoming.await(); runCurrent()
        assertEquals("姓名2", page.state.value.display.profiles[key]?.profile?.displayName())
        page.close(); receiver.close()
    }
    @Test fun `failed author denial persistence immediately clears the previously displayed name`() = runTest {
        var now = 0L; var writes = 0
        val page = ProfilePresentationPage(actor, device, { persistentListOf(available()) },
            { ProfileFenceSnapshot("one", it.associateWith { ProfileFence() }.toPersistentMap()) }, backgroundScope,
            nanoTime = { now }, localDisplays = LocalProfileDisplaySaving { _, _ ->
                if (++writes > 1) throw java.io.IOException("unavailable"); true
            })
        page.update(persistentListOf(key), "one"); advanceTimeBy(41); runCurrent()
        assertEquals(1, page.state.value.display.profiles.size)
        now = 1
        val receiver = AuthorPresentationReceiver(actor, device, { now })
        val view = receiver.begin("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", persistentListOf()); page.bindAuthor(view)
        val denial = ReceivedAuthorPresentationDelta(view, 1, persistentListOf(ReceivedAuthorPresentationEntry.Unavailable(
            ProfileReadResult.Unavailable(key, ProfileAuthority(2, null, 0, 0)), 10_000_000_000)))
        assertFailsWith<java.io.IOException> { page.ingestAuthor(denial) }
        assertTrue(page.state.value.display.profiles.isEmpty()); assertTrue(page.retainedAuthor(denial).isEmpty())
        page.close(); receiver.close()
    }
}
