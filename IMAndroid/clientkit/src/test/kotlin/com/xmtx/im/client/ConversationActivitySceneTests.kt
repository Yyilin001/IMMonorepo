package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationActivitySceneTests {
    private val self = UserId("self"); private val peer = UserId("peer"); private val room = RoomId("room")
    private val interest = ConversationActivityInterest(room, peer, hasDraft = true, onlineAllowed = true, typingAllowed = true)
    private inner class Wire(val scope: TestScope) {
        val calls = mutableListOf<String>(); var retired = false; var denied = false; var serial = 0L
        var typingGate: CompletableDeferred<Unit>? = null
        val connection = MutableStateFlow(RealtimeConnectionState(1, true))
        val events = MutableSharedFlow<RealtimeActivityEvent>()
        fun wall() = 1_000_000 + scope.testScheduler.currentTime
        fun nanos() = scope.testScheduler.currentTime * 1_000_000
        fun retire() { retired = true; connection.value = RealtimeConnectionState(1, false) }
        val activity = LiveActivitySubscriptionCoordinator(1, object : LiveActivityCommands {
            override suspend fun subscribeTyping(room: RoomId) { calls += "typing+"; if (denied) throw GatewayFailure("FORBIDDEN", false, 0) }
            override suspend fun unsubscribeTyping(room: RoomId) { calls += "typing-" }
            override suspend fun subscribePresence(room: RoomId): PresenceState { calls += "presence+"; return PresenceState(room, peer, true, wall() + 1000) }
            override suspend fun unsubscribePresence(room: RoomId) { calls += "presence-" }
            override suspend fun setTyping(room: RoomId, typing: Boolean) { calls += "type:$typing"; if (typing) typingGate?.await() }
            override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) { calls += "online:$mode" }
        }, events, connection, scope, { retire() }, wallMillis = ::wall, nanoTime = ::nanos)
        val roomEvents = RoomEventSubscriptionCoordinator(1, object : RoomEventSubscriptionCommands {
            override suspend fun subscribe(room: RoomId, appliedThrough: Long): RoomEventSubscription = error("scene must not acquire room events")
            override suspend fun unsubscribe(room: RoomId) = error("scene must not acquire room events")
        }, connection, emptyFlow(), scope, { true }, { 0 })
        val ports = RoomSubscriptionConnection(1, connection, roomEvents, activity, ::retire)
        suspend fun typing(user: UserId, target: RoomId = room) {
            events.emit(RealtimeActivityEvent(1, LiveActivityHint.Typing(TypingState(target, user, true, wall() + 1000)), ++serial, wall(), nanos()))
            scope.runCurrent()
        }
        fun close() { retire(); activity.close(); roomEvents.close() }
    }
    @Test fun `restored draft and reconnect do not publish until a fresh edit and renewals bind to observed connection`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this)
        val old = Wire(this); val next = Wire(this)
        try {
            scene.update(interest); val id = owner.attach(old.ports); runCurrent()
            advanceTimeBy(5000); runCurrent(); assertFalse(old.calls.any { it.startsWith("type:") })
            scene.updateTyping("first edit"); runCurrent(); assertEquals(1, old.calls.count { it == "type:true" })
            advanceTimeBy(4001); runCurrent(); assertEquals(2, old.calls.count { it == "type:true" })
            owner.detach(id); owner.attach(next.ports); runCurrent(); advanceTimeBy(5000); runCurrent()
            assertTrue(scene.state.value.subscribed); assertFalse(next.calls.any { it.startsWith("type:") })
            scene.update(interest); runCurrent(); assertFalse(next.calls.any { it.startsWith("type:") })
            scene.updateTyping("new edit"); runCurrent(); assertEquals(1, next.calls.count { it == "type:true" })
        } finally { scene.awaitClosed(); owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `two scenes share subscriptions and one scene stopping does not stop another publisher`() = runTest {
        val owner = RoomSubscriptions(self, this); val a = ConversationActivityScene(self, owner, this); val b = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            a.update(interest); b.update(interest); owner.attach(wire.ports); runCurrent()
            assertEquals(1, wire.calls.count { it == "typing+" }); assertEquals(1, wire.calls.count { it == "presence+" })
            a.updateTyping("a"); b.updateTyping("b"); runCurrent()
            a.updateTyping(""); runCurrent(); a.close(); runCurrent()
            assertFalse("type:false" in wire.calls); assertFalse("typing-" in wire.calls); assertTrue(b.state.value.subscribed)
            b.update(interest.copy(hasDraft = false)); runCurrent(); assertEquals(1, wire.calls.count { it == "type:false" })
            b.close(); runCurrent(); assertEquals(1, wire.calls.count { it == "typing-" }); assertFalse(wire.retired)
        } finally { a.awaitClosed(); b.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `direct scene filters self unrelated peer and room and shared TTL withdraws immutable values`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            scene.update(interest); owner.attach(wire.ports); runCurrent()
            wire.typing(self); wire.typing(UserId("stranger")); wire.typing(peer, RoomId("other")); assertTrue(scene.state.value.typing.isEmpty())
            wire.typing(peer); val previous = scene.state.value
            assertEquals(persistentSetOf(peer), previous.typing); assertEquals(true, previous.online)
            advanceTimeBy(1001); runCurrent(); assertTrue(scene.state.value.typing.isEmpty()); assertNull(scene.state.value.online)
            assertEquals(persistentSetOf(peer), previous.typing); assertEquals(true, previous.online)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `group scene observes all remote members without requesting presence or account publication policy`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            scene.update(interest.copy(group = true, peer = null)); owner.attach(wire.ports); runCurrent()
            wire.typing(self); wire.typing(peer); wire.typing(UserId("another"))
            assertEquals(persistentSetOf(peer, UserId("another")), scene.state.value.typing)
            assertNull(scene.state.value.online); assertEquals(listOf("typing+"), wire.calls)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `offline edits cannot become a queued positive publication after reconnect`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            scene.update(interest); scene.updateTyping("offline edit"); runCurrent()
            owner.attach(wire.ports); runCurrent(); advanceTimeBy(5000); runCurrent()
            assertFalse(wire.calls.any { it.startsWith("type:") })
            scene.updateTyping("online edit"); runCurrent(); assertTrue("type:true" in wire.calls)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `clearing or privacy withdrawal during positive admission retires only that connection`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val old = Wire(this); val next = Wire(this)
        try {
            scene.update(interest); owner.attach(old.ports); runCurrent(); old.typingGate = CompletableDeferred()
            scene.updateTyping("pending"); runCurrent(); scene.update(interest.copy(typingAllowed = false)); runCurrent()
            assertTrue(old.retired); assertFalse(scene.state.value.subscribed)
            owner.attach(next.ports); runCurrent(); scene.updateTyping("forbidden by local policy"); runCurrent()
            assertFalse(next.calls.any { it.startsWith("type:") }); assertFalse(next.retired)
        } finally { scene.awaitClosed(); owner.awaitClosed(); old.close(); next.close() }
    }
    @Test fun `leaving room releases intent and returning with old draft does not renew input`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            scene.update(interest); owner.attach(wire.ports); runCurrent(); scene.updateTyping("edit"); runCurrent()
            scene.update(ConversationActivityInterest()); runCurrent(); assertEquals(ConversationActivityState(), scene.state.value)
            assertTrue("typing-" in wire.calls); assertTrue("presence-" in wire.calls)
            val count = wire.calls.count { it == "type:true" }
            scene.update(interest); runCurrent(); advanceTimeBy(5000); runCurrent()
            assertEquals(count, wire.calls.count { it == "type:true" }); assertTrue(scene.state.value.subscribed)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `denial recovery refreshes observation but requires a new draft event to resume publishing`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            wire.denied = true; scene.update(interest); owner.attach(wire.ports); runCurrent()
            scene.updateTyping("not admitted"); runCurrent(); assertFalse(wire.calls.any { it.startsWith("type:") })
            wire.denied = false; owner.authorityDidChange(); runCurrent(); advanceTimeBy(5000); runCurrent()
            assertFalse(wire.calls.any { it.startsWith("type:") }); scene.updateTyping("new edit"); runCurrent()
            assertTrue("type:true" in wire.calls)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }
    @Test fun `scene shutdown drains an admitted publication and leaves account available for other consumers`() = runTest {
        val owner = RoomSubscriptions(self, this); val scene = ConversationActivityScene(self, owner, this); val wire = Wire(this)
        try {
            scene.update(interest); owner.attach(wire.ports); runCurrent(); wire.typingGate = CompletableDeferred()
            scene.updateTyping("pending"); runCurrent(); scene.awaitClosed()
            assertTrue(wire.retired); assertEquals(ConversationActivityState(), scene.state.value)
            val remaining = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Typing))
            assertEquals(RoomSubscriptionSnapshot(room), remaining.state.value); owner.release(remaining)
        } finally { scene.awaitClosed(); owner.awaitClosed(); wire.close() }
    }

}
