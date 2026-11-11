package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationActivitySessionTests {
    private val self = UserId("self"); private val peer = UserId("peer"); private val room = RoomId("room")
    private inner class Harness(val scope: TestScope) : AutoCloseable {
        val calls = mutableListOf<String>()
        var serial = 0L
        var wallOffset = 0L
        var disconnected = false
        var presenceGate: CompletableDeferred<Unit>? = null
        var typingGate: CompletableDeferred<Unit>? = null
        var seedOnline = true
        var presenceFailure: GatewayFailure? = null
        var typingFailure: GatewayFailure? = null
        var publicationFailure: GatewayFailure? = null
        val events = MutableSharedFlow<RealtimeActivityEvent>(extraBufferCapacity = 128)
        val connection = MutableStateFlow(RealtimeConnectionState(1,true))
        val commands = object : LiveActivityCommands {
            override suspend fun subscribePresence(room: RoomId): PresenceState {
                calls += "presence+ ${room.value}"
                presenceFailure?.let {throw it}
                val seed = PresenceState(room,peer,seedOnline,wall()+5_000)
                presenceGate?.await()
                return seed
            }
            override suspend fun unsubscribePresence(room: RoomId) { calls += "presence- ${room.value}" }
            override suspend fun subscribeTyping(room: RoomId) { calls += "typing+ ${room.value}";typingFailure?.let {throw it} }
            override suspend fun unsubscribeTyping(room: RoomId) { calls += "typing- ${room.value}" }
            override suspend fun setTyping(room: RoomId, typing: Boolean) { calls += "type $typing ${room.value}";publicationFailure?.let {throw it}; if(typing) typingGate?.await() }
            override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) { calls += "online $mode" }
        }
        fun wall() = 1_000_000L + scope.testScheduler.currentTime + wallOffset
        fun nanos() = scope.testScheduler.currentTime * 1_000_000
        val session = ConversationActivitySession(self,1,commands,events,connection,scope,{serial},{ _ -> disconnected=true},::wall,::nanos)
        fun open(group: Boolean=false,draft: Boolean=false) = session.update(ConversationActivityInterest(room,if(group)null else peer,group,draft,true,true))
        suspend fun event(hint: LiveActivityHint, epoch: Long=1, sequence: Long=++serial) {
            events.emit(RealtimeActivityEvent(epoch,hint,sequence,wall(),nanos())); scope.runCurrent()
        }
        suspend fun typing(user: UserId=peer,target: RoomId=room,active: Boolean=true,lease: Long=1_000) =
            event(LiveActivityHint.Typing(TypingState(target,user,active,wall()+lease)))
        override fun close() = session.close()
    }
    @Test fun `direct scope subscribes observes renews typing and tears down in order`() = runTest {
        Harness(this).use { h ->
            h.open(draft=true);runCurrent()
            assertTrue(h.session.state.value.subscribed);assertEquals(true,h.session.state.value.online)
            assertEquals(listOf("online AllowWhenAuthorized","typing+ room","presence+ room","type true room"),h.calls)
            advanceTimeBy(4_001);runCurrent()
            assertEquals(2,h.calls.count {it=="type true room"})
            h.open(draft=false);advanceTimeBy(250);runCurrent()
            assertEquals("type false room",h.calls.last())
            h.session.update(ConversationActivityInterest(onlineAllowed=true,typingAllowed=true))
            assertNull(h.session.state.value.room)
            advanceTimeBy(250);runCurrent()
            assertEquals(listOf("presence- room","typing- room"),h.calls.takeLast(2))
            assertFalse(h.disconnected)
        }
    }
    @Test fun `group excludes self and foreign room and bounds immutable typing membership`() = runTest {
        Harness(this).use { h ->
            h.open(group=true);runCurrent()
            assertFalse(h.calls.any {it.startsWith("presence+")})
            h.typing(self);h.typing(target=RoomId("foreign"))
            assertTrue(h.session.state.value.typing.isEmpty())
            repeat(70) { h.typing(UserId("member$it")) }
            assertEquals(64,h.session.state.value.typing.size)
            val before=h.session.state.value
            h.typing(UserId("member0"),active=false)
            assertEquals(64,before.typing.size);assertEquals(63,h.session.state.value.typing.size)
        }
    }
    @Test fun `lease expiry is monotonic and runs while network command is suspended`() = runTest {
        Harness(this).use { h ->
            h.open();runCurrent();h.typing(lease=1_000)
            assertEquals(persistentSetOf(peer),h.session.state.value.typing)
            h.typingGate=CompletableDeferred();h.open(draft=true);advanceTimeBy(250);runCurrent()
            h.wallOffset=-86_400_000
            advanceTimeBy(1_000);runCurrent()
            assertTrue(h.session.state.value.typing.isEmpty())
            advanceTimeBy(4_000);runCurrent()
            assertNull(h.session.state.value.online)
        }
    }
    @Test fun `newer hint during presence subscription wins over initial response`() = runTest {
        Harness(this).use { h ->
            h.presenceGate=CompletableDeferred();h.open();runCurrent()
            h.event(LiveActivityHint.Presence(PresenceState(room,peer,false,h.wall()+3_000)))
            assertNull(h.session.state.value.online)
            h.presenceGate!!.complete(Unit);runCurrent()
            assertEquals(false,h.session.state.value.online)
        }
    }
    @Test fun `switching room clears immediately and discards late subscription seed`() = runTest {
        Harness(this).use { h ->
            h.presenceGate=CompletableDeferred();h.open(draft=true);runCurrent()
            h.session.update(ConversationActivityInterest(RoomId("next"),peer,onlineAllowed=true,typingAllowed=true))
            assertEquals(RoomId("next"),h.session.state.value.room);assertNull(h.session.state.value.online)
            h.presenceGate!!.complete(Unit);runCurrent()
            assertFalse(h.calls.contains("type true room"))
            advanceTimeBy(250);runCurrent()
            assertTrue(h.calls.indexOf("typing- room")<h.calls.indexOf("typing+ next"))
            assertEquals(RoomId("next"),h.session.state.value.room)
        }
    }
    @Test fun `old connection and pre subscription events cannot resurrect a lease`() = runTest {
        Harness(this).use { h ->
            h.serial=20;h.open();runCurrent()
            val value=LiveActivityHint.Typing(TypingState(room,peer,true,h.wall()+1_000))
            h.event(value,epoch=2);h.event(value,sequence=20)
            assertTrue(h.session.state.value.typing.isEmpty())
            h.event(value);assertFalse(h.session.state.value.typing.isEmpty())
            h.connection.value=RealtimeConnectionState(1,false);runCurrent()
            assertEquals(ConversationActivityState(),h.session.state.value)
            h.event(value);assertTrue(h.session.state.value.typing.isEmpty());assertFalse(h.disconnected)
        }
    }
    @Test fun `old session teardown cannot disconnect a new epoch on the same transport`() = runTest {
        Harness(this).use { h ->
            h.open();runCurrent();h.typing()
            h.connection.value=RealtimeConnectionState(2,true);runCurrent()
            assertEquals(ConversationActivityState(),h.session.state.value)
            assertFalse(h.disconnected)
            h.session.close();assertFalse(h.disconnected)
        }
    }
    @Test fun `privacy tightening interrupts queued positive publication and does not loosen itself`() = runTest {
        Harness(this).use { h ->
            h.typingGate=CompletableDeferred();h.open(draft=true);runCurrent()
            h.session.update(ConversationActivityInterest(room,peer,hasDraft=true,onlineAllowed=true,typingAllowed=false))
            assertTrue(h.disconnected);assertEquals(ConversationActivityState(),h.session.state.value)
            h.typingGate!!.complete(Unit);runCurrent();advanceTimeBy(5_000);runCurrent()
            assertEquals(1,h.calls.count {it=="type true room"})
            h.open(draft=true);runCurrent();assertEquals(1,h.calls.count {it=="type true room"})
        }
    }
    @Test fun `coverage loss hides immediately and resubscribes while stale revisions cannot clear ready state`() = runTest {
        Harness(this).use { h ->
            h.open();runCurrent();h.typing()
            h.event(LiveActivityHint.Coverage(room,ActivityChannel.Typing,ActivityCoverageState.Recovering,5,1))
            assertTrue(h.session.state.value.subscribed);assertEquals(true,h.session.state.value.online);assertTrue(h.session.state.value.typing.isEmpty())
            advanceTimeBy(250);runCurrent()
            assertEquals(2,h.calls.count {it=="typing+ room"})
            h.event(LiveActivityHint.Coverage(room,ActivityChannel.Typing,ActivityCoverageState.Ready,7,2))
            h.typing()
            h.event(LiveActivityHint.Coverage(room,ActivityChannel.Typing,ActivityCoverageState.Ended,6,1))
            h.event(LiveActivityHint.Coverage(room,ActivityChannel.Typing,ActivityCoverageState.Ended,8,1))
            assertTrue(h.session.state.value.subscribed);assertEquals(persistentSetOf(peer),h.session.state.value.typing)
        }
    }
    @Test fun `direct scope ignores unauthorized target and positive command stops on route exit`() = runTest {
        Harness(this).use { h ->
            h.open();runCurrent();h.typing(UserId("stranger"))
            h.event(LiveActivityHint.Presence(PresenceState(room,UserId("stranger"),false,h.wall()+1_000)))
            assertTrue(h.session.state.value.typing.isEmpty());assertEquals(true,h.session.state.value.online)
            h.typingGate=CompletableDeferred();h.open(draft=true);advanceTimeBy(250);runCurrent()
            h.session.update(ConversationActivityInterest(onlineAllowed=true,typingAllowed=true))
            assertTrue(h.disconnected);assertNull(h.session.state.value.room)
        }
    }
    @Test fun `typing subscription denial preserves presence and never retries on a draft change or late hint`() = runTest {
        Harness(this).use {h->
            h.typingFailure=GatewayFailure("FORBIDDEN",false,0)
            h.session.update(ConversationActivityInterest(room,peer,hasDraft=true,onlineAllowed=true,typingAllowed=false));runCurrent()
            assertFalse(h.disconnected);assertTrue(h.session.state.value.subscribed);assertEquals(true,h.session.state.value.online)
            h.typing();assertTrue(h.session.state.value.typing.isEmpty())
            advanceTimeBy(9000);runCurrent();assertEquals(1,h.calls.count {it=="typing+ room"});assertFalse(h.calls.any {it.startsWith("type ")})
            h.typingFailure=null
            h.session.update(ConversationActivityInterest(room,peer,hasDraft=true,onlineAllowed=true,typingAllowed=true))
            h.event(LiveActivityHint.Coverage(room,ActivityChannel.Presence,ActivityCoverageState.Ready,1,1))
            advanceTimeBy(250);runCurrent()
            assertEquals(2,h.calls.count {it=="typing+ room"});assertEquals(1,h.calls.count {it=="type true room"})
            h.typing();assertEquals(persistentSetOf(peer),h.session.state.value.typing);assertFalse(h.disconnected)
        }
    }
    @Test fun `presence denial leaves typing usable and a different room retries its own authority`() = runTest {
        Harness(this).use {h->
            h.presenceFailure=GatewayFailure("FORBIDDEN",false,0);h.open(draft=true);runCurrent();h.typing()
            assertFalse(h.disconnected);assertNull(h.session.state.value.online);assertTrue(h.session.state.value.subscribed)
            assertEquals(persistentSetOf(peer),h.session.state.value.typing)
            h.event(LiveActivityHint.Presence(PresenceState(room,peer,true,h.wall()+5000)))
            assertNull(h.session.state.value.online)
            advanceTimeBy(8000);runCurrent();assertEquals(1,h.calls.count {it=="presence+ room"})
            h.presenceFailure=null;h.session.update(ConversationActivityInterest(RoomId("other"),peer,onlineAllowed=true,typingAllowed=true))
            advanceTimeBy(250);runCurrent();assertEquals(true,h.session.state.value.online)
            assertEquals(1,h.calls.count {it=="presence+ other"});assertFalse(h.disconnected)
        }
    }
    @Test fun `publication rejection clears typing but does not poison the shared connection`() = runTest {
        Harness(this).use {h->
            h.open();runCurrent();h.typing();h.publicationFailure=GatewayFailure("FORBIDDEN",false,0)
            h.open(draft=true);advanceTimeBy(250);runCurrent()
            assertFalse(h.disconnected);assertTrue(h.session.state.value.typing.isEmpty());assertEquals(true,h.session.state.value.online)
            h.typing();advanceTimeBy(8000);runCurrent()
            assertTrue(h.session.state.value.typing.isEmpty());assertEquals(1,h.calls.count {it=="type true room"})
            h.session.update(ConversationActivityInterest(onlineAllowed=true,typingAllowed=true));advanceTimeBy(250);runCurrent()
            assertFalse(h.disconnected);assertEquals("typing- room",h.calls.last())
        }
    }
    @Test fun `false typing rejection on route exit is harmless and retryable denials still close`() = runTest {
        Harness(this).use {h->
            h.open(draft=true);runCurrent();h.publicationFailure=GatewayFailure("FORBIDDEN",false,0)
            h.session.update(ConversationActivityInterest(onlineAllowed=true,typingAllowed=true));advanceTimeBy(250);runCurrent()
            assertFalse(h.disconnected);assertEquals(listOf("type false room","presence- room","typing- room"),h.calls.takeLast(3))
        }
        Harness(this).use {h->
            h.typingFailure=GatewayFailure("FORBIDDEN",true,1);h.open();runCurrent()
            assertTrue(h.disconnected);assertEquals(ConversationActivityState(),h.session.state.value)
        }
    }
}
