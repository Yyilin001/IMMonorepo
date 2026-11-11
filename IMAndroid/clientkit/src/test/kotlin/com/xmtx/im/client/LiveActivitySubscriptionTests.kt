package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class LiveActivitySubscriptionTests {
    private val room = RoomId("room"); private val peer = UserId("peer")
    private inner class Harness(val scope: TestScope, maxRooms: Int = 128, maxConsumers: Int = 512) : AutoCloseable {
        val events = MutableSharedFlow<RealtimeActivityEvent>(extraBufferCapacity = 128)
        val connection = MutableStateFlow(RealtimeConnectionState(1, true))
        val calls = mutableListOf<String>()
        var gate: CompletableDeferred<Unit>? = null
        var transportFailure = false; var denied = false; var allowed = true; var offset = 0L; var disconnected = false; var serial = 0L
        fun wall() = 1_000_000 + scope.testScheduler.currentTime + offset
        fun nanos() = scope.testScheduler.currentTime * 1_000_000
        val commands = object : LiveActivityCommands {
            override suspend fun subscribePresence(room: RoomId): PresenceState {
                calls += "presence+"; val seed = PresenceState(room, peer, true, wall() + 2000); gate?.await()
                if (denied) throw GatewayFailure("FORBIDDEN", false, 0)
                return seed
            }
            override suspend fun unsubscribePresence(room: RoomId) { calls += "presence-" }
            override suspend fun subscribeTyping(room: RoomId) { calls += "typing+"; gate?.await(); if (transportFailure) throw java.io.IOException("fixture connection lost"); if (denied) throw GatewayFailure("FORBIDDEN", false, 0) }
            override suspend fun unsubscribeTyping(room: RoomId) { calls += "typing-" }
            override suspend fun setTyping(room: RoomId, typing: Boolean) { calls += "type:$typing" }
            override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) { calls += "mode:$mode" }
        }
        val owner = LiveActivitySubscriptionCoordinator(1, commands, events, connection, scope,
            { disconnected = true }, { allowed }, ::wall, ::nanos, maxRooms, maxConsumers)
        suspend fun event(hint: LiveActivityHint, epoch: Long = 1) {
            events.emit(RealtimeActivityEvent(epoch, hint, ++serial, wall(), nanos())); scope.runCurrent()
        }
        override fun close() { owner.close() }
    }
    @Test fun `two consumers share each channel and last release alone unsubscribes`() = runTest {
        Harness(this).use { h ->
            val one = h.owner.acquire(room, persistentSetOf(ActivityChannel.Presence, ActivityChannel.Typing))
            val two = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            assertEquals(listOf("presence+", "typing+"), h.calls)
            assertEquals(persistentSetOf(ActivityChannel.Typing), two.state.value.confirmed); assertNull(two.state.value.presence)
            h.owner.release(one); runCurrent(); assertEquals(1, h.calls.count { it == "presence-" }); assertFalse("typing-" in h.calls)
            assertEquals(LiveActivitySubscriptionSnapshot(room), one.state.value)
            h.owner.release(two); runCurrent(); assertEquals(1, h.calls.count { it == "typing-" }); assertFalse(h.disconnected)
        }
    }
    @Test fun `cancelled facade waiter leaves shared in flight subscribe for other consumer`() = runTest {
        Harness(this).use { h ->
            h.gate = CompletableDeferred(); val a = h.owner.consumerCommands(); val b = h.owner.consumerCommands()
            val first = launch { a.subscribeTyping(room) }; val second = async { b.subscribeTyping(room) }; runCurrent()
            assertEquals(listOf("typing+"), h.calls); first.cancelAndJoin(); h.gate!!.complete(Unit); second.await(); runCurrent()
            assertFalse("typing-" in h.calls); b.unsubscribeTyping(room); runCurrent(); assertEquals(1, h.calls.count { it == "typing-" })
            assertFalse(h.disconnected)
        }
    }
    @Test fun `newer presence observation wins over suspended seed and expiry remains monotonic`() = runTest {
        Harness(this).use { h ->
            h.gate = CompletableDeferred(); val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Presence)); runCurrent()
            h.event(LiveActivityHint.Presence(PresenceState(room, peer, false, h.wall() + 1000)))
            h.gate!!.complete(Unit); runCurrent(); assertEquals(false, lease.state.value.presence!!.online)
            val old = lease.state.value; h.offset = -86_400_000; advanceTimeBy(1001); runCurrent()
            assertNull(lease.state.value.presence); assertEquals(false, old.presence!!.online)
        }
    }
    @Test fun `one publisher stopping does not clear another publishers typing intent`() = runTest {
        Harness(this).use { h ->
            val one = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); val two = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            h.owner.setTyping(one, 1, true); h.owner.setTyping(two, 1, true)
            h.owner.setTyping(one, 1, false); assertFalse("type:false" in h.calls)
            h.owner.release(two); runCurrent(); assertEquals(1, h.calls.count { it == "type:false" }); assertFalse("typing-" in h.calls)
            assertFailsWith<IllegalArgumentException> { h.owner.setTyping(one, 2, true) }
        }
    }
    @Test fun `coverage loss clears lease and ended generation cannot be revived by stale ready`() = runTest {
        Harness(this).use { h ->
            val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            h.event(LiveActivityHint.Typing(TypingState(room, peer, true, h.wall() + 5000)))
            h.event(LiveActivityHint.Coverage(room, ActivityChannel.Typing, ActivityCoverageState.Ended, 2, 1))
            assertTrue(lease.state.value.typing.isEmpty()); assertTrue(lease.state.value.confirmed.isEmpty())
            h.event(LiveActivityHint.Coverage(room, ActivityChannel.Typing, ActivityCoverageState.Ready, 3, 1))
            assertTrue(lease.state.value.confirmed.isEmpty()); advanceTimeBy(1001); runCurrent()
            assertEquals(2, h.calls.count { it == "typing+" })
            h.event(LiveActivityHint.Coverage(room, ActivityChannel.Typing, ActivityCoverageState.Ready, 4, 2))
            assertEquals(persistentSetOf(ActivityChannel.Typing), lease.state.value.confirmed)
        }
    }
    @Test fun `typing values are bounded channel scoped and old connection is ignored`() = runTest {
        Harness(this).use { h ->
            val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            h.event(LiveActivityHint.Typing(TypingState(room, peer, true, h.wall() + 1000)), 2)
            assertTrue(lease.state.value.typing.isEmpty())
            repeat(70) { h.event(LiveActivityHint.Typing(TypingState(room, UserId("u$it"), true, h.wall() + 1000))) }
            val old = lease.state.value; assertEquals(64, old.typing.size)
            h.event(LiveActivityHint.Typing(TypingState(room, UserId("u0"), false, 0))); assertEquals(63, lease.state.value.typing.size)
            advanceTimeBy(1001); runCurrent(); assertTrue(lease.state.value.typing.isEmpty()); assertEquals(64, old.typing.size)
        }
    }
    @Test fun `explicit denial does not poll and authority change retries without late old seed`() = runTest {
        Harness(this).use { h ->
            h.denied = true; val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Presence)); runCurrent()
            assertEquals(persistentSetOf(ActivityChannel.Presence), lease.state.value.denied)
            advanceTimeBy(3000); runCurrent(); assertEquals(1, h.calls.count { it == "presence+" })
            h.denied = false; h.gate = CompletableDeferred(); h.owner.authorityDidChange(); runCurrent()
            h.allowed = false; h.owner.authorityDidChange(); h.gate!!.complete(Unit); runCurrent()
            assertNull(lease.state.value.presence); assertTrue(lease.state.value.confirmed.isEmpty())
            h.allowed = true; h.owner.authorityDidChange(); runCurrent(); assertEquals(true, lease.state.value.presence!!.online)
        }
    }
    @Test fun `replacement epoch and owner shutdown withdraw all leased values`() = runTest {
        Harness(this).use { h ->
            val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Presence)); runCurrent()
            h.connection.value = RealtimeConnectionState(2, true); runCurrent()
            assertEquals(LiveActivitySubscriptionSnapshot(room), lease.state.value); assertFalse(h.disconnected)
            assertFailsWith<RealtimeUnavailableBeforeAdmission> { h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)) }
        }
    }
    @Test fun `bounded capacity counts all consumers and pending wire cleanup`() = runTest {
        Harness(this, 1, 2).use { h ->
            assertFailsWith<IllegalArgumentException> { h.owner.acquire(room, persistentSetOf()) }
            h.gate = CompletableDeferred()
            val first = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); val second = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            assertFailsWith<IllegalStateException> { h.owner.acquire(room, persistentSetOf(ActivityChannel.Presence)) }
            h.owner.release(first); h.owner.release(second)
            assertFailsWith<IllegalStateException> { h.owner.acquire(RoomId("other"), persistentSetOf(ActivityChannel.Typing)) }
            h.gate!!.complete(Unit); runCurrent()
            val next = h.owner.acquire(RoomId("other"), persistentSetOf(ActivityChannel.Typing)); runCurrent()
            assertEquals(persistentSetOf(ActivityChannel.Typing), next.state.value.confirmed)
        }
    }
    @Test fun `transport failure withdraws waiting snapshots and ends only owning connection`() = runTest {
        Harness(this).use { h ->
            h.transportFailure = true
            val lease = h.owner.acquire(room, persistentSetOf(ActivityChannel.Typing)); runCurrent()
            assertTrue(h.disconnected); assertEquals(LiveActivitySubscriptionSnapshot(room), lease.state.value)
            assertFailsWith<RealtimeUnavailableBeforeAdmission> { h.owner.awaitConfirmed(lease) }
        }
    }
    @Test fun `closing one conversation releases only its leases while another stays subscribed`() = runTest {
        Harness(this).use { h ->
            fun scene() = ConversationActivitySession(UserId("self"), 1, h.owner.consumerCommands(), h.events, h.connection,
                this, { h.serial }, { h.disconnected = true }, h::wall, h::nanos, disconnectOnClose = false)
            val first = scene(); val second = scene()
            try {
                val interest = ConversationActivityInterest(room, peer, hasDraft = true, onlineAllowed = true, typingAllowed = true)
                first.update(interest); second.update(interest); runCurrent()
                assertTrue(second.state.value.subscribed); assertEquals(1, h.calls.count { it == "typing+" })
                first.close(); runCurrent(); assertFalse(h.disconnected); assertTrue(second.state.value.subscribed)
                assertFalse("typing-" in h.calls); assertFalse("type:false" in h.calls)
                second.close(); runCurrent(); assertEquals(1, h.calls.count { it == "typing-" }); assertFalse(h.disconnected)
            } finally { first.close(); second.close() }
        }
    }
    @Test fun `existing conversation session uses shared command facade without changing privacy and lease expiry`() = runTest {
        Harness(this).use { h ->
            val session = ConversationActivitySession(UserId("self"), 1, h.owner.consumerCommands(), h.events, h.connection,
                this, { h.serial }, { h.disconnected = true }, h::wall, h::nanos, disconnectOnClose = false)
            try {
                session.update(ConversationActivityInterest(room, peer, hasDraft = true, onlineAllowed = true, typingAllowed = true)); runCurrent()
                assertTrue(session.state.value.subscribed); assertEquals(true, session.state.value.online); assertTrue("type:true" in h.calls)
                h.event(LiveActivityHint.Typing(TypingState(room, peer, true, h.wall() + 1000)))
                assertEquals(persistentSetOf(peer), session.state.value.typing)
                advanceTimeBy(1001); runCurrent(); assertTrue(session.state.value.typing.isEmpty())
                session.update(ConversationActivityInterest(room, peer)); assertTrue(h.disconnected)
            } finally { session.close() }
        }
    }
}
