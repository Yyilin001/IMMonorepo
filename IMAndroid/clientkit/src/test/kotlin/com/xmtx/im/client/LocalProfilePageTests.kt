package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class LocalProfilePageTests {
    private val f = AvatarFixture()
    private val keys get() = persistentListOf(f.key)
    private fun snapshot(profile: AuthorizedProfile = f.available().profile): LocalProfileDisplaySnapshot {
        val value = LocalProfileDisplay.from(profile)!!
        return LocalProfileDisplaySnapshot(persistentMapOf(value.key to value), persistentMapOf(value.key.user to LocalProfileBasics.merge(value)))
    }
    private fun fences(keys: PersistentList<ProfileKey>, generation: String = "one", floor: ProfileFence = ProfileFence()) =
        ProfileFenceSnapshot(generation, keys.associateWith { floor }.toPersistentMap())

    @Test fun `local text loads while HTTP is stalled and cannot grant an avatar`() = runTest {
        val page = ProfilePresentationPage(f.actor, f.device, { awaitCancellation() }, { fences(it) }, backgroundScope,
            localDisplayReader = LocalProfileDisplayReading { _, _ -> snapshot() })
        page.update(keys, "one", keys); advanceTimeBy(41); runCurrent()
        assertEquals("好友 B", page.state.value.display.localNames?.get(f.key)?.name)
        assertTrue(page.state.value.display.profiles.isEmpty()); assertTrue(page.state.value.display.avatars.isEmpty())
        assertNull(page.avatarReadGrant(f.key)); page.close(); assertEquals(ProfilePageSnapshot(), page.state.value)
    }

    @Test fun `avatar and lease expire while local text and public identity remain`() = runTest {
        var calls = 0
        val page = ProfilePresentationPage(f.actor, f.device, {
            if (++calls > 1) awaitCancellation()
            persistentListOf(f.available(deadline = 100_000_000, download = 100_000_000))
        }, { fences(it) }, backgroundScope, nanoTime = { testScheduler.currentTime * 1_000_000 },
            avatarReader = { AvatarDownloadedBytes(ByteString.copyFrom(f.bytes), it) },
            localDisplayReader = LocalProfileDisplayReading { _, _ -> snapshot() })
        page.update(keys, "one", keys); advanceTimeBy(41); runCurrent()
        assertEquals(1, page.state.value.display.avatars.size)
        advanceTimeBy(100); runCurrent()
        assertTrue(page.state.value.display.avatars.isEmpty()); assertTrue(page.state.value.display.profiles.isEmpty())
        assertEquals("好友 B", page.state.value.display.localNames?.get(f.key)?.name)
        assertEquals(f.target, page.state.value.display.localNames?.get(f.key)?.identity?.user)
        assertNull(page.avatarReadGrant(f.key)); page.close()
    }

    @Test fun `cache changes reach multiple pages without HTTP and denial never falls back to live name`() = runTest {
        val changes = MutableStateFlow(0L); var local = snapshot()
        fun page() = ProfilePresentationPage(f.actor, f.device, { persistentListOf(f.available()) }, { fences(it) }, backgroundScope,
            nanoTime = { f.clock }, localDisplayReader = LocalProfileDisplayReading { _, _ -> local }, localDisplayChanges = changes)
        val first = page(); val second = page()
        first.update(keys, "one"); second.update(keys, "one"); advanceTimeBy(41); runCurrent()
        assertEquals("好友 B", first.state.value.display.localNames?.get(f.key)?.name)
        local = local.copy(deniedKeys = persistentSetOf(f.key)); changes.value++; runCurrent()
        for (p in listOf(first, second)) {
            assertTrue(p.state.value.display.localNames!!.isEmpty())
            assertEquals(1, p.state.value.display.profiles.size) // A live lease is separate from authoritative local text.
            p.close()
        }
    }

    @Test fun `security change during a noncooperative load cannot publish old text`() = runTest {
        var generation = "one"; val gate = CompletableDeferred<Unit>(); var reads = 0
        val page = ProfilePresentationPage(f.actor, f.device, { awaitCancellation() }, { fences(it, generation) }, backgroundScope,
            localDisplayReader = LocalProfileDisplayReading { _, _ ->
                if (++reads == 1) withContext(NonCancellable) { gate.await(); snapshot() } else LocalProfileDisplaySnapshot()
            })
        page.update(keys, generation); runCurrent(); assertEquals(1, reads)
        generation = "two"; page.observeGeneration(generation); runCurrent(); gate.complete(Unit); runCurrent()
        assertTrue(page.state.value.display.localNames!!.isEmpty()); page.close()
    }

    @Test fun `viewport and owner retirement reject late local values and unrequested contexts`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val page = ProfilePresentationPage(f.actor, f.device, { awaitCancellation() }, { fences(it) }, backgroundScope,
            localDisplayReader = LocalProfileDisplayReading { _, _ -> withContext(NonCancellable) { gate.await(); snapshot() } })
        page.update(keys, "one"); runCurrent(); page.update(persistentListOf(), "one"); gate.complete(Unit); runCurrent()
        assertTrue(page.state.value.display.localNames!!.isEmpty()); page.close()
        val pending = CompletableDeferred<Unit>()
        val other = ProfilePresentationPage(f.actor, f.device, { awaitCancellation() }, { fences(it) }, backgroundScope,
            localDisplayReader = LocalProfileDisplayReading { _, _ -> withContext(NonCancellable) { pending.await(); snapshot() } })
        other.update(keys, "one"); runCurrent(); other.close(); pending.complete(Unit); runCurrent()
        assertEquals(ProfilePageSnapshot(), other.state.value)
    }

    @Test fun `security floor suppresses old text while ordinary content floor keeps it`() = runTest {
        var floor = ProfileFence(minimumProfileRevision = 100)
        val changes = MutableStateFlow(0L)
        val page = ProfilePresentationPage(f.actor, f.device, { awaitCancellation() }, { fences(it, floor = floor) }, backgroundScope,
            localDisplayReader = LocalProfileDisplayReading { _, _ -> snapshot() }, localDisplayChanges = changes)
        page.update(keys, "one"); runCurrent(); assertEquals("好友 B", page.state.value.display.localNames?.get(f.key)?.name)
        floor = ProfileFence(securityRevision = 100); changes.value++; runCurrent()
        assertTrue(page.state.value.display.localNames!!.isEmpty()); page.close()
    }

    @Test fun `missing changed or failing local reads do not synthesize cached text from a live response`() = runTest {
        val changes = MutableStateFlow(0L); var mode = 0
        val page = ProfilePresentationPage(f.actor, f.device, { persistentListOf(f.available()) }, { fences(it) }, backgroundScope,
            nanoTime = { f.clock }, localDisplayReader = LocalProfileDisplayReading { _, _ -> when (mode) {
                0 -> null
                1 -> throw java.io.IOException()
                else -> snapshot()
            } }, localDisplayChanges = changes)
        page.update(keys, "one"); advanceTimeBy(41); runCurrent()
        assertTrue(page.state.value.display.localNames!!.isEmpty()); assertEquals(1, page.state.value.display.profiles.size)
        mode = 1; changes.value++; runCurrent(); assertTrue(page.state.value.display.localNames!!.isEmpty())
        mode = 2; changes.value++; runCurrent(); assertEquals("好友 B", page.state.value.display.localNames?.get(f.key)?.name)
        assertNull(page.state.value.display.localNames?.get(ProfileKey(f.target, ProfileContext.DirectConversation)))
        page.close()
    }
}
