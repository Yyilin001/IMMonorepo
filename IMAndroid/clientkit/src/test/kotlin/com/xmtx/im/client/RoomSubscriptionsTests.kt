package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RoomSubscriptionsTests {
    private val room = RoomId("room")
    private val all = RoomSubscriptionChannel.entries.toPersistentSet()
    private inner class Connection(scope: TestScope) {
        val state = MutableStateFlow(RealtimeConnectionState(1, true))
        val hints = MutableSharedFlow<RealtimeSyncEvent>()
        val activityHints = MutableSharedFlow<RealtimeActivityEvent>()
        val calls = mutableListOf<String>()
        var cursor = 0L; var allowed = true; var denied = false; var retired = false
        var gate: CompletableDeferred<Unit>? = null
        var typingGate: CompletableDeferred<Unit>? = null
        var ignoreCancellation = false
        var serial = 0L
        val events = RoomEventSubscriptionCoordinator(1, object : RoomEventSubscriptionCommands {
            override suspend fun subscribe(room: RoomId, appliedThrough: Long): RoomEventSubscription {
                calls += "events+:$appliedThrough"
                if (ignoreCancellation) withContext(NonCancellable) { gate?.await() } else gate?.await()
                calls += "events-ack"
                if (denied) throw GatewayFailure("FORBIDDEN", false, 0)
                return RoomEventSubscription(room, 10, 1)
            }
            override suspend fun unsubscribe(room: RoomId) { calls += "events-" }
        }, state, hints, scope, { allowed }, { cursor })
        val activity = LiveActivitySubscriptionCoordinator(1, object : LiveActivityCommands {
            override suspend fun subscribePresence(room: RoomId): PresenceState {
                calls += "presence+"; if (denied) throw GatewayFailure("FORBIDDEN", false, 0)
                return PresenceState(room, UserId("peer"), true, 1_010_000)
            }
            override suspend fun unsubscribePresence(room: RoomId) { calls += "presence-" }
            override suspend fun subscribeTyping(room: RoomId) { calls += "typing+"; if (denied) throw GatewayFailure("FORBIDDEN", false, 0) }
            override suspend fun unsubscribeTyping(room: RoomId) { calls += "typing-" }
            override suspend fun setTyping(room: RoomId, typing: Boolean) { calls += "type:$typing"; typingGate?.await() }
            override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) {}
        }, activityHints, state, scope, { retire() }, { allowed }, { 1_000_000 + scope.testScheduler.currentTime }, { scope.testScheduler.currentTime * 1_000_000 })
        fun retire() { retired = true; state.value = RealtimeConnectionState(1, false) }
        val ports = RoomSubscriptionConnection(1, state, events, activity, ::retire)
        suspend fun typing() { activityHints.emit(RealtimeActivityEvent(1,
            LiveActivityHint.Typing(TypingState(room, UserId("peer"), true, 1_010_000)), ++serial, 1_000_000, 0)) }
        fun close() { retire(); events.close(); activity.close() }
    }
    @Test fun `stable intent survives replacement with reused transport epoch but facts and typing never replay`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val first = Connection(this); val second = Connection(this)
        try {
            val lease = owner.acquire(room, all); assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            val oldId = owner.attach(first.ports); owner.reconcile(oldId); runCurrent(); first.typing(); runCurrent()
            owner.setTyping(lease, oldId, true)
            val old = lease.state.value
            assertEquals(all, old.confirmed); assertEquals(10, old.baselineHead); assertFalse(old.isCaughtUp)
            assertEquals(1, old.typing.size); assertNotNull(old.presence)
            first.cursor = 10; owner.reconcile(oldId); runCurrent(); assertTrue(lease.state.value.isCaughtUp)
            owner.detach(oldId); assertEquals(RoomSubscriptionSnapshot(room), lease.state.value); assertTrue(first.retired)
            second.cursor = 3
            val newId = owner.attach(second.ports); assertNotEquals(oldId, newId)
            assertFailsWith<RealtimeUnavailableBeforeAdmission> { owner.setTyping(lease, oldId, true) }
            owner.reconcile(newId); runCurrent()
            assertEquals(newId, lease.state.value.connectionId); assertEquals(3, lease.state.value.appliedThrough)
            assertTrue(lease.state.value.typing.isEmpty()); assertFalse(second.calls.any { it.startsWith("type:") })
            assertEquals(1, old.typing.size); assertEquals(0, old.appliedThrough)
            owner.detach(oldId); assertEquals(newId, lease.state.value.connectionId); assertFalse(second.retired)
        } finally { owner.awaitClosed(); first.close(); second.close() }
    }
    @Test fun `all consumers restore only their desired channels and last release unsubscribes`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val c = Connection(this)
        try {
            val a = owner.acquire(room, all)
            val b = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Typing))
            val removed = owner.acquire(RoomId("unused"), all); owner.release(removed)
            val id = owner.attach(c.ports); owner.reconcile(id); runCurrent()
            assertEquals(1, c.calls.count { it == "typing+" }); assertEquals(1, c.calls.count { it.startsWith("events+:") })
            assertEquals(persistentSetOf(RoomSubscriptionChannel.Typing), b.state.value.confirmed)
            assertNull(b.state.value.baselineHead); assertNull(b.state.value.presence)
            owner.release(a); owner.reconcile(id); runCurrent()
            assertTrue("events-" in c.calls); assertTrue("presence-" in c.calls); assertFalse("typing-" in c.calls)
            owner.release(b); runCurrent(); assertEquals(1, c.calls.count { it == "typing-" })
            assertEquals(RoomSubscriptionSnapshot(room), a.state.value)
        } finally { owner.awaitClosed(); c.close() }
    }
    @Test fun `replacement drains late uncooperative old acknowledgement before restoring intents`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val old = Connection(this); val next = Connection(this)
        try {
            val lease = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.RoomEvents))
            old.gate = CompletableDeferred(); old.ignoreCancellation = true
            val oldId = owner.attach(old.ports)
            val reconcile = async { runCatching { owner.reconcile(oldId) } }; runCurrent()
            val replacing = async { owner.attach(next.ports) }; runCurrent()
            assertTrue(old.retired); assertFalse(replacing.isCompleted); assertTrue(next.calls.isEmpty())
            assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            old.gate!!.complete(Unit); val newId = replacing.await(); reconcile.await(); owner.reconcile(newId); runCurrent()
            assertEquals(newId, lease.state.value.connectionId); assertFalse(next.retired)
            old.hints.emit(RealtimeSyncEvent(1, RealtimeSyncHint.Room(room, 100))); runCurrent()
            assertEquals(10, lease.state.value.observedHead)
        } finally { old.gate?.complete(Unit); owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `cancelled replacement retires incoming ports without losing account intent`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val old = Connection(this); val unused = Connection(this); val next = Connection(this)
        try {
            val lease = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.RoomEvents))
            old.gate = CompletableDeferred(); old.ignoreCancellation = true
            val id = owner.attach(old.ports); val work = async { runCatching { owner.reconcile(id) } }; runCurrent()
            val cancelled = launch { owner.attach(unused.ports) }; runCurrent(); cancelled.cancel(); runCurrent()
            old.gate!!.complete(Unit); cancelled.join(); work.await()
            assertTrue(unused.retired); assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            val restored = owner.attach(next.ports); owner.reconcile(restored); runCurrent()
            assertEquals(RoomSubscriptionStatus.Subscribed, lease.state.value.status)
        } finally { old.gate?.complete(Unit); owner.awaitClosed(); old.close(); unused.close(); next.close() }
    }
    @Test fun `cancelled positive publication retires its connection and never replays into replacement`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val old = Connection(this); val next = Connection(this)
        try {
            val lease = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Typing))
            val id = owner.attach(old.ports); runCurrent(); old.typingGate = CompletableDeferred()
            val publishing = launch { owner.setTyping(lease, id, true) }; runCurrent()
            publishing.cancelAndJoin(); assertTrue(old.retired); assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            owner.attach(next.ports); runCurrent(); assertEquals(listOf("typing+"), next.calls)
        } finally { owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `physical disconnect clears facts but retains choices for a fresh connection`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val old = Connection(this); val next = Connection(this)
        try {
            val lease = owner.acquire(room, all); val id = owner.attach(old.ports); owner.reconcile(id); runCurrent()
            old.state.value = RealtimeConnectionState(1, false); runCurrent()
            assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            owner.release(lease)
            val fresh = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Presence))
            owner.attach(next.ports); runCurrent()
            assertEquals(listOf("presence+"), next.calls); assertEquals(persistentSetOf(RoomSubscriptionChannel.Presence), fresh.state.value.confirmed)
        } finally { owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `authority updates both channel owners and explicit denial does not poll`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val c = Connection(this)
        try {
            c.denied = true; val lease = owner.acquire(room, all); val id = owner.attach(c.ports)
            owner.reconcile(id); runCurrent(); assertEquals(RoomSubscriptionStatus.Revoked, lease.state.value.status)
            val count = c.calls.size; advanceTimeBy(2000); owner.reconcile(id); runCurrent(); assertEquals(count, c.calls.size)
            c.denied = false; owner.authorityDidChange(); owner.reconcile(id); runCurrent()
            assertEquals(all, lease.state.value.confirmed)
            c.allowed = false; owner.authorityDidChange(); owner.reconcile(id); runCurrent()
            assertEquals(RoomSubscriptionStatus.Revoked, lease.state.value.status); assertTrue(lease.state.value.confirmed.isEmpty())
            assertNull(lease.state.value.presence); assertNull(lease.state.value.baselineHead)
        } finally { owner.awaitClosed(); c.close() }
    }
    @Test fun `foreign or released tokens cannot mutate membership and capacity is bounded offline`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this, 1, 2); val foreign = RoomSubscriptions(UserId("other"), this)
        try {
            assertFailsWith<IllegalArgumentException> { owner.acquire(room, persistentSetOf()) }
            val a = owner.acquire(room, all); val b = owner.acquire(room, all)
            assertFailsWith<IllegalStateException> { owner.acquire(room, all) }
            foreign.release(a); owner.release(b)
            assertFailsWith<IllegalStateException> { owner.acquire(RoomId("other"), all) }
            assertFailsWith<IllegalStateException> { owner.setTyping(b, "old", true) }
            owner.release(a); val fresh = owner.acquire(RoomId("other"), all)
            owner.close(); assertEquals(RoomSubscriptionSnapshot(fresh.room), fresh.state.value)
            assertFailsWith<IllegalStateException> { owner.acquire(room, all) }
        } finally { owner.awaitClosed(); foreign.awaitClosed() }
    }
    @Test fun `account cancellation withdraws snapshots and actual transport before shutdown returns`() = runTest {
        val parent = Job(); val owner = RoomSubscriptions(UserId("self"), CoroutineScope(coroutineContext + parent)); val c = Connection(this)
        try {
            val lease = owner.acquire(room, all); val id = owner.attach(c.ports); owner.reconcile(id); runCurrent()
            parent.cancel(); runCurrent(); owner.awaitClosed()
            assertTrue(c.retired); assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
        } finally { owner.awaitClosed(); c.close(); parent.cancel() }
    }
    @Test fun `new intent during disconnect notification handoff restores on the next physical connection`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val old = Connection(this); val next = Connection(this)
        try {
            val id = owner.attach(old.ports); runCurrent()
            old.state.value = RealtimeConnectionState(1, false)
            // Do not run the queued watcher: acquisition must tolerate the state it has not seen yet.
            val lease = owner.acquire(room, all)
            assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
            val fresh = owner.attach(next.ports); owner.reconcile(fresh); runCurrent()
            owner.detach(id); assertEquals(all, lease.state.value.confirmed); assertFalse(next.retired)
        } finally { owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `already cancelled publication cannot admit a command or retire a healthy connection`() = runTest {
        val owner = RoomSubscriptions(UserId("self"), this); val c = Connection(this)
        try {
            val lease = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Typing))
            val id = owner.attach(c.ports); runCurrent()
            val caller = launch {
                currentCoroutineContext().cancel()
                assertFailsWith<CancellationException> { owner.setTyping(lease, id, true) }
            }
            caller.join(); assertFalse(c.calls.any { it.startsWith("type:") }); assertFalse(c.retired)
        } finally { owner.awaitClosed(); c.close() }
    }

}
