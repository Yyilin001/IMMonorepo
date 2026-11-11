package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RoomEventSubscriptionTests {
    private val room = RoomId("room")
    private class Commands : RoomEventSubscriptionCommands {
        val calls = mutableListOf<String>()
        var head = 10L
        var denied = false
        var gate: CompletableDeferred<Unit>? = null
        override suspend fun subscribe(room: RoomId, appliedThrough: Long): RoomEventSubscription {
            calls += "subscribe:${room.value}:$appliedThrough"; gate?.await()
            if (denied) throw GatewayFailure("FORBIDDEN", false, 0)
            return RoomEventSubscription(room, head, 1)
        }
        override suspend fun unsubscribe(room: RoomId) { calls += "unsubscribe:${room.value}" }
    }
    private class Fixture(scope: CoroutineScope, val maximumRooms: Int = 128, val maximumConsumers: Int = 512) {
        val commands = Commands()
        val connection = MutableStateFlow(RealtimeConnectionState(1, true))
        val events = MutableSharedFlow<RealtimeSyncEvent>()
        var allowed = true
        var cursor = 0L
        var readGate: CompletableDeferred<Unit>? = null
        val seeds = mutableListOf<RoomEventSubscription>()
        val revoked = mutableListOf<RoomId>()
        val owner = RoomEventSubscriptionCoordinator(1, commands, connection, events, scope,
            { allowed }, { readGate?.await(); cursor }, seeds::add, { revoked += it },
            maximumRooms = maximumRooms, maximumConsumers = maximumConsumers)
    }
    @Test fun `shared leases subscribe once and last release alone unsubscribes`() = runTest {
        val f = Fixture(this)
        try {
            val first = f.owner.acquire(room); val second = f.owner.acquire(room)
            f.owner.reconcile(); assertEquals(listOf("subscribe:room:0"), f.commands.calls)
            f.owner.release(first); f.owner.reconcile()
            assertEquals(RoomSubscriptionStatus.Offline, first.state.value.status)
            assertEquals(RoomSubscriptionStatus.Subscribed, second.state.value.status); assertEquals(1, f.commands.calls.size)
            f.owner.release(second); f.owner.reconcile()
            assertEquals(listOf("subscribe:room:0", "unsubscribe:room"), f.commands.calls)
            f.owner.release(second); f.owner.reconcile(); assertEquals(2, f.commands.calls.size)
        } finally { f.owner.close() }
    }
    @Test fun `installation baseline stays fixed while applied cursor and availability advance independently`() = runTest {
        val f = Fixture(this)
        try {
            val lease = f.owner.acquire(room); f.owner.reconcile()
            val old = lease.state.value; assertEquals(10, old.baselineHead); assertFalse(old.isCaughtUp)
            f.events.emit(RealtimeSyncEvent(1, RealtimeSyncHint.Room(room, 30))); runCurrent()
            assertEquals(30, lease.state.value.observedHead); assertEquals(10, lease.state.value.baselineHead); assertFalse(lease.state.value.isCaughtUp)
            f.cursor = 10; f.owner.reconcile(); assertTrue(lease.state.value.isCaughtUp)
            assertEquals(0, old.appliedThrough); assertEquals(10, old.observedHead)
            f.events.emit(RealtimeSyncEvent(2, RealtimeSyncHint.Room(room, 100))); runCurrent(); assertEquals(30, lease.state.value.observedHead)
        } finally { f.owner.close() }
    }
    @Test fun `release during subscribe never revives released state and pending installation is cleaned`() = runTest {
        val f = Fixture(this)
        try {
            val lease = f.owner.acquire(room); f.commands.gate = CompletableDeferred()
            val running = launch { f.owner.reconcile() }; runCurrent()
            f.owner.release(lease); f.commands.gate!!.complete(Unit); running.join()
            assertEquals(RoomSubscriptionStatus.Offline, lease.state.value.status); assertTrue(f.seeds.isEmpty())
            f.owner.reconcile(); assertEquals("unsubscribe:room", f.commands.calls.last())
        } finally { f.owner.close() }
    }
    @Test fun `forbidden remains revoked without polling until explicit authority change`() = runTest {
        val f = Fixture(this)
        try {
            f.commands.denied = true; val lease = f.owner.acquire(room); f.owner.reconcile(); f.owner.reconcile()
            assertEquals(RoomSubscriptionStatus.Revoked, lease.state.value.status); assertEquals(1, f.commands.calls.size); assertEquals(listOf(room), f.revoked)
            f.commands.denied = false; f.owner.authorityDidChange(); f.owner.reconcile()
            assertEquals(RoomSubscriptionStatus.Subscribed, lease.state.value.status); assertEquals(2, f.commands.calls.size)
            f.allowed = false; f.owner.authorityDidChange(); f.owner.reconcile()
            assertEquals(RoomSubscriptionStatus.Revoked, lease.state.value.status); assertNull(lease.state.value.baselineHead)
            assertEquals("unsubscribe:room", f.commands.calls.last())
        } finally { f.owner.close() }
    }
    @Test fun `authority changes during cursor read prevent stale subscribe and require a fresh baseline`() = runTest {
        val f = Fixture(this)
        try {
            val lease = f.owner.acquire(room); f.readGate = CompletableDeferred()
            val running = launch { f.owner.reconcile() }; runCurrent()
            f.allowed = false; f.owner.authorityDidChange(); f.readGate!!.complete(Unit); running.join()
            assertTrue(f.commands.calls.isEmpty()); assertEquals(RoomSubscriptionStatus.Revoked, lease.state.value.status)
            f.allowed = true; f.owner.authorityDidChange(); f.owner.reconcile(); assertEquals(10, lease.state.value.baselineHead)
            f.commands.head = 20; f.owner.authorityDidChange(); f.owner.reconcile()
            assertEquals(listOf("subscribe:room:0", "unsubscribe:room", "subscribe:room:0"), f.commands.calls)
            assertEquals(20, lease.state.value.baselineHead)
        } finally { f.owner.close() }
    }
    @Test fun `replaced connection withdraws every lease and late subscribe cannot publish`() = runTest {
        val f = Fixture(this)
        try {
            val lease = f.owner.acquire(room); f.commands.gate = CompletableDeferred()
            val running = async { runCatching { f.owner.reconcile() } }; runCurrent()
            f.connection.value = RealtimeConnectionState(2, true); runCurrent()
            assertEquals(RoomEventSubscriptionSnapshot(room), lease.state.value)
            f.commands.gate!!.complete(Unit); assertIs<RealtimeUnavailableBeforeAdmission>(running.await().exceptionOrNull())
            assertTrue(f.seeds.isEmpty()); assertFailsWith<RealtimeUnavailableBeforeAdmission> { f.owner.acquire(room) }
        } finally { f.owner.close() }
    }
    @Test fun `authority change during acknowledgement cleans old installation and ignores stale denial`() = runTest {
        val f = Fixture(this)
        try {
            val lease = f.owner.acquire(room); f.commands.gate = CompletableDeferred()
            val first = launch { f.owner.reconcile() }; runCurrent()
            f.owner.authorityDidChange(); f.commands.gate!!.complete(Unit); first.join()
            assertNull(lease.state.value.baselineHead); assertTrue(f.seeds.isEmpty())
            f.commands.head = 20; f.owner.reconcile()
            assertEquals(listOf("subscribe:room:0", "unsubscribe:room", "subscribe:room:0"), f.commands.calls)
            assertEquals(20, lease.state.value.baselineHead)
            f.commands.gate = CompletableDeferred(); f.commands.denied = true; f.owner.authorityDidChange()
            val second = launch { f.owner.reconcile() }; runCurrent()
            f.owner.authorityDidChange(); f.commands.gate!!.complete(Unit); second.join()
            assertTrue(f.revoked.isEmpty())
            f.commands.denied = false; f.owner.reconcile(); assertEquals(RoomSubscriptionStatus.Subscribed, lease.state.value.status)
        } finally { f.owner.close() }
    }
    @Test fun `failed durable cursor read withdraws all snapshots instead of retaining caught up state`() = runTest {
        val connection = MutableStateFlow(RealtimeConnectionState(1, true)); val commands = Commands(); var fail = false
        val owner = RoomEventSubscriptionCoordinator(1, commands, connection, MutableSharedFlow(), this,
            { true }, { if (fail) error("storage unavailable") else 10 })
        val lease = owner.acquire(room); owner.reconcile(); assertTrue(lease.state.value.isCaughtUp)
        fail = true; assertFailsWith<IllegalStateException> { owner.reconcile() }
        assertEquals(RoomEventSubscriptionSnapshot(room), lease.state.value)
        owner.close()
    }
    @Test fun `capacity counts consumers and pending unsubscribe rooms and foreign releases do not remove leases`() = runTest {
        val f = Fixture(this, 1, 2); val other = Fixture(this)
        try {
            val first = f.owner.acquire(room); f.owner.acquire(room)
            assertFailsWith<IllegalStateException> { f.owner.acquire(room) }
            assertFailsWith<IllegalStateException> { f.owner.acquire(RoomId("other")) }
            other.owner.release(first); f.owner.reconcile(); assertEquals(RoomSubscriptionStatus.Subscribed, first.state.value.status)
            f.owner.release(first); assertFailsWith<IllegalStateException> { f.owner.acquire(RoomId("other")) }
        } finally { f.owner.close(); other.owner.close() }
    }
    @Test fun `cancelled owner clears current values without issuing cleanup on replacement connection`() = runTest {
        val parent = Job(); val f = Fixture(CoroutineScope(coroutineContext + parent))
        val lease = f.owner.acquire(room); f.owner.reconcile(); parent.cancel(); runCurrent()
        assertEquals(RoomEventSubscriptionSnapshot(room), lease.state.value)
        assertEquals(listOf("subscribe:room:0"), f.commands.calls)
        f.owner.close()
    }
}
