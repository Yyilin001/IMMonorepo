package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

class AccountPreferenceClockTests {
    @Test fun `server deadline survives restart while device admission controls submit and close`() = runTest {
        val store = MemoryPreferences()
        var local = 1_000_000_000L
        var mono = 0L
        val server = ServerTimeAnchor { mono }.apply { observe(1_000) }
        val api = FakeEdge { _, _ -> EdgeResponse(200, preferenceBaseline(preferenceValues[2])) }
        fun service() = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { local }, { mono }, server::now)
        var service = service()
        service.enqueue(PreferencePatch(PreferenceKind.ReadReceipts, first = true))
        service.flush()
        val frozen = requireNotNull(store.works.single().command)
        assertEquals(116_000, frozen.deadline)
        assertEquals(1_000_115_000, store.works.single().confirmedUntil)
        // Losing the time source must not alter an already frozen command or prevent its recovery.
        server.reset()
        service = service()
        api.answer = { path, body ->
            assertTrue(path.endsWith("/submit")); assertEquals(frozen.payload(), body)
            throw IOException("lost response")
        }
        service.flush()
        local += 5_000; mono += 5_000_000_000
        api.answer = { path, body ->
            assertTrue(path.endsWith("/recover")); assertEquals(frozen.recovery(false), body)
            EdgeResponse(200, directResult("unresolved", buildJsonObject {}))
        }
        service = service(); service.flush()
        local += 115_000; mono += 115_000_000_000
        api.answer = { path, body ->
            assertTrue(path.endsWith("/recover")); assertEquals(frozen.recovery(true), body)
            EdgeResponse(200, directResult("unresolved", buildJsonObject {}))
        }
        service = service(); service.flush()
        assertEquals(frozen, store.works.single().command)
    }

    @Test fun `wall clock rollback cannot extend the active confirmation window`() = runTest {
        val store = MemoryPreferences()
        var local = 1_000_000_000L
        var mono = 0L
        val anchor = ServerTimeAnchor { mono }.apply { observe(2_000_000_000) }
        val api = FakeEdge { _, _ ->
            local -= 86_400_000; mono += 10_000_000_000
            EdgeResponse(200, preferenceBaseline(preferenceValues[2]))
        }
        val service = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { local }, { mono }, anchor::now)
        service.enqueue(PreferencePatch(PreferenceKind.ReadReceipts, first = true)); service.flush()
        val frozen = requireNotNull(store.works.single().command)
        assertEquals(2_000_115_000, frozen.deadline)
        mono = 115_000_000_000
        api.answer = { _, body ->
            assertEquals(frozen.recovery(true), body)
            EdgeResponse(200, directResult("unresolved", buildJsonObject {}))
        }
        service.flush()
        assertEquals(frozen, store.works.single().command)
    }

    @Test fun `missing time defers preparation without freezing a device time command`() = runTest {
        val store = MemoryPreferences()
        var local = 1_000L
        var mono = 0L
        val anchor = ServerTimeAnchor { mono }
        val api = FakeEdge { path, _ ->
            assertTrue(path.endsWith("/baseline"))
            EdgeResponse(200, preferenceBaseline(preferenceValues[2]))
        }
        val service = AccountPreferenceService(actorId, AccountPreferenceClient(api, actorId), store, { local }, { mono }, anchor::now)
        service.enqueue(PreferencePatch(PreferenceKind.ReadReceipts, first = true)); service.flush()
        assertNull(store.works.single().command)
        assertEquals(PreferenceStatus.DraftReady, store.works.single().status)
        local = store.works.single().nextAttemptMilliseconds
        mono = (local - 1_000) * 1_000_000
        anchor.observe(500_000)
        service.flush()
        assertEquals(500_000 + 115_000 - (local - 1_000), store.works.single().command!!.deadline)
    }
}
