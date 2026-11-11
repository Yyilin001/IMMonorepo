package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeSyncTests {
    @Test fun `snapshot deferral preserves drained and newer room watermarks with bounded overflow recovery`() = runTest {
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this)
        try {
            val room=RoomId("snapshot-room");queue.room(room,8)
            val drained=queue.take();queue.room(room,12)
            queue.deferForSnapshot(drained)
            val resumed=queue.take();assertTrue(resumed.account);assertEquals(12,resumed.rooms.single().head);assertTrue(resumed.rooms.single().force)
            repeat(64) {queue.room(RoomId("cold-$it"),1)}
            queue.deferForSnapshot(drained)
            val overflow=queue.take();assertTrue(overflow.refreshDirectory);assertTrue(overflow.account)
        } finally {queue.close()}
    }
    private val room=RoomId("00000000-0000-0000-0000-000000000001")
    @Test fun `hints coalesce and arrivals during suspended work survive the next turn`() = runTest {
        val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=128)
        val queue=RealtimeSyncWakeups(3,events,this)
        try {
            events.emit(RealtimeSyncEvent(2,RealtimeSyncHint.Room(room,99)));runCurrent()
            assertTrue(queue.take().rooms.isEmpty())
            queue.room(room,3);queue.room(room,9);queue.account();queue.account()
            val first=queue.take();assertTrue(first.account);assertEquals(9,first.rooms.single().head)
            queue.room(room,10);queue.account()
            assertEquals(9,first.rooms.single().head)
            val second=queue.take();assertEquals(10,second.rooms.single().head);assertTrue(second.account)
            assertFalse(queue.take().account)
        } finally {queue.close()}
    }
    @Test fun `bounded room queue falls back to directory and hot room cannot jump ahead of cold work`() = runTest {
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this)
        try {
            repeat(70) {queue.room(RoomId("room$it"),it.toLong())}
            val first=queue.take(4);assertTrue(first.refreshDirectory);assertEquals(4,first.rooms.size)
            assertEquals(RoomId("room0"),first.rooms.first().room)
            queue.room(RoomId("room0"),100)
            val second=queue.take(4);assertEquals(RoomId("room4"),second.rooms.first().room)
            val remaining=mutableListOf<RoomSyncWake>()
            repeat(16) {remaining+=queue.take(4).rooms}
            assertEquals(57,remaining.size);assertEquals(RoomId("room0"),remaining.last().room)
        } finally {queue.close()}
    }
    @Test fun `retry deadline is honored without blocking an unrelated room`() = runTest {
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this,{testScheduler.currentTime*1_000_000})
        try {
            queue.room(room,10,true,2_000);queue.room(RoomId("other"),3)
            assertEquals(RoomId("other"),queue.take().rooms.single().room)
            queue.room(room,11) // A new hint cannot bypass the server's retry deadline.
            assertTrue(queue.take().rooms.isEmpty())
            val wait=async {queue.await(5_000)};runCurrent();assertFalse(wait.isCompleted)
            advanceTimeBy(1_999);runCurrent();assertFalse(wait.isCompleted)
            advanceTimeBy(1);runCurrent();assertTrue(wait.isCompleted)
            assertEquals(11,queue.take().rooms.single().head)
        } finally {queue.close()}
    }
    @Test fun `negative monotonic origin does not postpone immediate work or shorten retry`() = runTest {
        var now=-5_000_000_000L
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this,{now})
        try {
            queue.room(room,1);assertEquals(1,queue.take().rooms.single().head)
            queue.room(room,2,true,1_000);assertTrue(queue.take().rooms.isEmpty())
            now=-4_000_000_000;assertEquals(2,queue.take().rooms.single().head)
        } finally {queue.close()}
    }
    @Test fun `coverage loss requests authorized pull without asserting applied cursor or accepting stale generation`() = runTest {
        val events=MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity=8)
        val queue=RealtimeSyncWakeups(1,events,this)
        try {
            val latest=RealtimeSyncHint.Coverage(SyncCoverageScope.Room,room.value,5,2,50,ActivityCoverageState.Recovering,SyncCoverageReason.Lost)
            events.emit(RealtimeSyncEvent(1,latest));runCurrent()
            val work=queue.take();assertEquals(50,work.rooms.single().head);assertTrue(work.rooms.single().force)
            events.emit(RealtimeSyncEvent(1,latest.copy(revision=6,generation=1,head=100)));runCurrent()
            assertTrue(queue.take().rooms.isEmpty())
            events.emit(RealtimeSyncEvent(1,latest.copy(state=ActivityCoverageState.Ready,reason=SyncCoverageReason.Confirmed,revision=7)));runCurrent()
            assertTrue(queue.take().rooms.single().force)
        } finally {queue.close()}
    }
    @Test fun `selection wakes sleeping runtime and closing stops further event intake`() = runTest {
        val queue=RealtimeSyncWakeups(1,MutableSharedFlow(),this)
        val waiting=async {queue.await(5_000)};runCurrent();assertFalse(waiting.isCompleted)
        queue.select(room);runCurrent();assertTrue(waiting.isCompleted);assertEquals(room,queue.take().selectedRoom)
        queue.close();queue.room(room,100);assertTrue(queue.take().rooms.isEmpty())
    }
    @Test fun `wire coverage enforces lifecycle reason identity and unsigned bounds`() {
        val wire=RealtimeCoverage.newBuilder().setScope(RealtimeCoverage.Scope.ROOM).setScopeId(room.value)
            .setRevision(1).setScopeGeneration(1).setHighWatermark(9).setState(RealtimeCoverage.State.READY)
        fun decode()=RealtimeSyncHint.decode(Envelope.newBuilder().setRealtimeCoverage(wire).build())
        assertEquals(9,(decode() as RealtimeSyncHint.Coverage).head)
        wire.setReason(RealtimeCoverage.Reason.COVERAGE_LOST);assertFailsWith<ClientFailure.Protocol> {decode()}
        wire.setState(RealtimeCoverage.State.RECOVERING);assertEquals(SyncCoverageReason.Lost,(decode() as RealtimeSyncHint.Coverage).reason)
        wire.setScopeGeneration(-1);assertFailsWith<ClientFailure.Protocol> {decode()}
        wire.setScopeGeneration(1).setScopeId("not-a-uuid");assertFailsWith<ClientFailure.Protocol> {decode()}
        val invalid=Envelope.newBuilder().setSyncAvailable(SyncAvailable.newBuilder().setHighWatermark(-1)).build()
        assertFailsWith<ClientFailure.Protocol> {RealtimeSyncHint.decode(invalid)}
    }
    @Test fun `subscription response must match room and acknowledgements never become cursor evidence`() = runTest {
        var response=Envelope.newBuilder().setGroupEventSubscribed(GroupEventSubscribed.newBuilder().setRoomId(room.value).setHighWatermark(2).setMembershipRevision(3)).build()
        var sent: Envelope?=null
        val client=RoomEventSubscriptionClient(object: EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {sent=body.build();return response}})
        assertEquals(RoomEventSubscription(room,2,3),client.subscribe(room,10)) // A baseline may be below our cursor.
        assertEquals(10,sent!!.groupEventSubscribe.afterRoomSequence)
        response=response.toBuilder().apply {groupEventSubscribed=groupEventSubscribed.toBuilder().setRoomId("other").build()}.build()
        assertFailsWith<ClientFailure.Protocol> {client.subscribe(room,10)}
        assertFailsWith<ClientFailure.Protocol> {client.unsubscribe(room)}
        response=Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
        client.unsubscribe(room);assertEquals(room.value,sent!!.groupEventUnsubscribe.roomId)
    }
}
