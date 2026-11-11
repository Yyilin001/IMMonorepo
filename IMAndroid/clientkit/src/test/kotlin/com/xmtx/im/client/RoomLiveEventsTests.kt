package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RoomLiveEventsTests {
    private val room=RoomId("00000000-0000-0000-0000-000000000001")
    private fun event(sequence: Long) = RoomLiveEvent("10000000-0000-0000-0000-${sequence.toString().padStart(12,'0')}",sequence,"message",
        ByteString.copyFromUtf8("""{"room_id":"${room.value}","room_sequence":$sequence}"""))
    private fun wire(event: RoomLiveEvent)=GroupEvent.newBuilder().setSourceEventId(event.source).setRoomSequence(event.sequence).setProjectionKind(event.kind).setPayload(event.payload).build()
    private fun hint(head: Long,vararg sequences: Long)=RealtimeSyncHint.Room(room,head,sequences.map(::event).toPersistentList())
    private fun decode(body: GroupEventAvailable.Builder)=RealtimeSyncHint.decode(Envelope.newBuilder().setGroupEventAvailable(body).build()) as RealtimeSyncHint.Room
    private fun body()=GroupEventAvailable.newBuilder().setRoomId(room.value).setHighWatermark(10)
    @Test fun `optional legacy and batch bodies preserve head while malformed bodies degrade to metadata`() {
        val e=event(2)
        val legacy=body().setSourceEventId(e.source.lowercase()).setRoomSequence(e.sequence).setProjectionKind(e.kind).setEventPayload(e.payload)
        assertEquals(persistentListOf(e),decode(legacy).liveEvents)
        assertEquals(10,decode(legacy).head)
        assertEquals(listOf(2L,3L),decode(body().addLiveEvents(wire(e)).addLiveEvents(wire(event(3)))).liveEvents.map {it.sequence})
        val invalid=listOf(e.copy(source="bad"),e.copy(sequence=0),e.copy(sequence=11),e.copy(kind=""),e.copy(payload=ByteString.EMPTY))
        for(bad in invalid) {val decoded=decode(body().addLiveEvents(wire(bad)));assertEquals(10,decoded.head);assertTrue(decoded.liveEvents.isEmpty())}
        assertTrue(decode(body().addLiveEvents(wire(e)).addLiveEvents(wire(event(4)))).liveEvents.isEmpty())
        assertTrue(decode(body().addLiveEvents(wire(e)).addLiveEvents(wire(e))).liveEvents.isEmpty())
        assertTrue(decode(legacy.addLiveEvents(wire(e.copy(sequence=0)))).liveEvents.isEmpty()) // Batch wins over legacy.
    }
    @Test fun `decoder rejects optional body count and memory excess without losing watermark`() {
        val tooMany=body().setHighWatermark(600).addAllLiveEvents((1L..501).map {wire(event(it))})
        assertTrue(decode(tooMany).liveEvents.isEmpty())
        assertTrue(decode(body().addLiveEvents(wire(event(1).copy(payload=ByteString.copyFrom(ByteArray(1_048_576)))))).liveEvents.isEmpty())
        assertEquals(500,decode(body().setHighWatermark(500).addAllLiveEvents((1L..500).map {wire(event(it))})).liveEvents.size)
    }
    @Test fun `same head fills sparse pending bodies conflicts drop acceleration and snapshots remain immutable`()=runTest {
        val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=8);val queue=RealtimeSyncWakeups(1,events,this)
        try {
            events.emit(RealtimeSyncEvent(1,hint(5,3)));events.emit(RealtimeSyncEvent(1,hint(4,1,2)));runCurrent()
            val first=queue.take().rooms.single();assertEquals(5,first.head);assertEquals(listOf(1L,2L,3L),first.liveEvents.map {it.sequence})
            queue.room(room,5,liveEvents=first.liveEvents);queue.room(room,5,liveEvents=persistentListOf(event(2).copy(kind="room")))
            assertTrue(queue.take().rooms.single().liveEvents.isEmpty());assertEquals(3,first.liveEvents.size)
            events.emit(RealtimeSyncEvent(0,hint(10,4)));runCurrent();assertTrue(queue.take().rooms.isEmpty())
        } finally {queue.close()}
    }
    @Test fun `coalescing keeps newest bounded events and inbox pressure retains durable recovery work`()=runTest {
        val merged=RoomLiveEvents.merge(600,(1L..400).map(::event).toPersistentList(),(401L..600).map(::event).toPersistentList())
        assertEquals(500,merged.size);assertEquals(101,merged.first().sequence)
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this)
        try {
            val big=persistentListOf(event(1).copy(payload=ByteString.copyFrom(ByteArray(1_000_000))))
            repeat(20) {queue.room(RoomId("room$it"),1,liveEvents=big)}
            val all=queue.take(16).rooms+queue.take(16).rooms
            assertEquals(20,all.size);assertTrue(all.sumOf {RoomLiveEvents.bytes(it.liveEvents)} <= RoomLiveEvents.inboxBytes)
            assertTrue(all.any {it.liveEvents.isEmpty()});assertTrue(all.all {it.head==1L})
        } finally {queue.close()}
    }
    private class Store : LiveRoomStore {
        var cursor=RoomCursor();var authorized=true;var fail=false;var commits=0;var gate: CompletableDeferred<Unit>?=null
        override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId,RoomKind>)=error("Unexpected directory")
        override suspend fun acceptStates(states: kotlinx.collections.immutable.PersistentMap<RoomId,RoomSyncState>) {states.forEach {(room,state) -> acceptState(room,state)}}
        override suspend fun acceptState(room: RoomId,state: RoomSyncState) {authorized=true}
        override suspend fun unavailable(room: RoomId) {authorized=false}
        override suspend fun roomCursor(room: RoomId)=cursor
        override suspend fun commitRoom(page: GroupEventPage,expected: RoomCursor) {cursor=RoomCursor(page.nextRoomSequence)}
        override suspend fun commitLiveRoom(page: GroupEventPage,expected: RoomCursor): Boolean {
            gate?.await()
            if(!authorized || cursor != expected) return false
            if(fail) throw IOException()
            commits++;cursor=RoomCursor(page.nextRoomSequence,expected.historyIncomplete);return true
        }
    }
    private class Wire(val store: Store): EnvelopeTransport {
        var acks=0;var retry=false;var failAck=false
        override suspend fun request(body: Envelope.Builder): Envelope {
            val command=body.build()
            if(command.hasRoomSyncStateBatch() && retry) return Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder()
                .addRooms(RoomSyncStateResult.newBuilder().setRoomId(command.roomSyncStateBatch.getRoomIds(0)).setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(2)))).build()
            assertTrue(command.hasDeviceRoomProgressReport(),"Live body must not make a pull or grant request")
            assertEquals(store.cursor.sequence,command.deviceRoomProgressReport.getRooms(0).appliedThrough)
            if(failAck) throw IOException()
            acks++
            return Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(command.deviceRoomProgressReport.roomsList)).build()
        }
    }
    @Test fun `continuous prefix commits before delivery ack duplicates skip and gap never advances head`()=runTest {
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store)
        assertFalse(engine.applyOnlineEvents(hint(5,1,2,4,5)));assertEquals(2,store.cursor.sequence);assertEquals(1,wire.acks)
        assertFalse(engine.applyOnlineEvents(hint(5,1,2,4,5)));assertEquals(1,wire.acks)
        assertTrue(engine.applyOnlineEvents(hint(5,1,2,3,4,5)));assertEquals(5,store.cursor.sequence);assertEquals(2,wire.acks)
        assertTrue(engine.applyOnlineEvents(hint(5,5)));assertEquals(2,wire.acks)
    }
    @Test fun `live batch supports 500 events without widening durable page limits or clearing incomplete history`()=runTest {
        val store=Store().apply {cursor=RoomCursor(0,true)};val wire=Wire(store)
        assertTrue(RoomSyncEngine(wire,store).applyOnlineEvents(hint(500,*(1L..500).toList().toLongArray())))
        assertEquals(RoomCursor(500,true),store.cursor)
        val page=GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(500).addAllEvents((1L..500).map {wire(event(it))}).build()
        assertFailsWith<ClientFailure.Protocol> {RoomSyncEngine.validatePage(room,RoomCursor(),page)}
    }
    @Test fun `busy store missing authority CAS failure and failed commit never acknowledge`()=runTest {
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store)
        store.authorized=false;assertFalse(engine.applyOnlineEvents(hint(1,1)));assertEquals(0,wire.acks)
        store.authorized=true;store.fail=true;assertFailsWith<IOException> {engine.applyOnlineEvents(hint(1,1))};assertEquals(0,wire.acks)
        store.fail=false;val gate=CompletableDeferred<Unit>();store.gate=gate
        val flight=async {engine.applyOnlineEvents(hint(1,1))};runCurrent()
        assertFalse(engine.applyOnlineEvents(hint(1,1)));assertEquals(0,wire.acks)
        store.cursor=RoomCursor(1);gate.complete(Unit);assertFalse(flight.await());assertEquals(0,wire.acks)
    }
    @Test fun `retry window cannot be bypassed by body and failed ack leaves committed cursor durable`()=runTest {
        var now=0L;val store=Store();val wire=Wire(store).apply {retry=true};val engine=RoomSyncEngine(wire,store,{now})
        assertEquals(2_000,engine.synchronizeRoom(room).retryAfterMillis)
        assertFalse(engine.applyOnlineEvents(hint(1,1)));assertEquals(0,store.commits)
        now=2_000_000_000;wire.failAck=true
        assertFailsWith<IOException> {engine.applyOnlineEvents(hint(1,1))};assertEquals(1,store.cursor.sequence)
        wire.failAck=false;assertTrue(engine.applyOnlineEvents(hint(1,1)));assertEquals(1,store.commits)
    }
    @Test fun `out of order oversized or foreign room bodies never commit`()=runTest {
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store)
        assertFalse(engine.applyOnlineEvents(hint(3,1,3,2)));assertFalse(engine.applyOnlineEvents(hint(1,2)))
        val bad=event(1).copy(payload=ByteString.copyFromUtf8("""{"room_id":"other"}"""))
        assertFailsWith<ClientFailure.Protocol> {engine.applyOnlineEvents(RealtimeSyncHint.Room(room,1,persistentListOf(bad)))}
        val huge=event(1).copy(payload=ByteString.copyFrom(ByteArray(1_048_576) {32}))
        assertTrue(runCatching {engine.applyOnlineEvents(RealtimeSyncHint.Room(room,1,persistentListOf(huge)))}.isFailure)
        assertEquals(0,store.commits);assertEquals(0,wire.acks)
    }
}
