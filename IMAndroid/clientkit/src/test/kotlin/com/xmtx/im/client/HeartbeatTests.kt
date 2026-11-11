package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class HeartbeatTests {
    private val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private class Wire(var scope: RoomProgressScope?): EnvelopeTransport,RoomProgressConnection {
        override var authenticatedEpoch: Long?=1
        var sent: Heartbeat?=null
        var beforeReply: ()->Unit={}
        var result=Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.getDefaultInstance()).build()
        val accepted=mutableListOf<Pair<RoomProgressScope,Long>>()
        override fun roomProgressScope()=scope
        override suspend fun request(body: Envelope.Builder): Envelope {error("must bind heartbeat to its original connection")}
        override suspend fun requestHeartbeat(heartbeat: Heartbeat,expectedEpoch: Long): Envelope {
            if(authenticatedEpoch!=expectedEpoch) throw RealtimeUnavailableBeforeAdmission()
            sent=heartbeat;beforeReply();return result
        }
        override fun acceptRoomProgressHead(scope: RoomProgressScope,head: Long) {accepted.add(scope to head)}
    }
    private fun wire(head: Long=20)=Wire(RoomProgressScope(1,room,3,10)).apply {
        result=ack(GroupEventProgressState.newBuilder().setRoomId(room.value.lowercase()).setScopeGeneration(3)
            .setHighWatermark(head).setAppliedRoomSequence(7).setReady(true).build())
    }
    private fun ack(vararg states: GroupEventProgressState)=Envelope.newBuilder().setHeartbeatAck(
        HeartbeatAck.newBuilder().addAllRoomSubscriptionStates(states.asList())).build()
    @Test fun `only committed local cursor is reported and server observation only wakes recovery`()=runTest {
        val wire=wire();var committed=4L
        HeartbeatClient(wire) {assertEquals(room,it);committed}.send(123)
        assertEquals(123,wire.sent!!.clientTimeMs)
        val report=wire.sent!!.roomProgressList.single()
        assertEquals(room.value,report.roomId);assertEquals(3,report.scopeGeneration);assertEquals(4,report.appliedRoomSequence)
        assertEquals(listOf(wire.scope!! to 20L),wire.accepted);assertEquals(4,committed)
    }
    @Test fun `heartbeat without durable proof still accepts current ready head`()=runTest {
        val wire=wire()
        HeartbeatClient(wire) {null}.send(-1)
        assertEquals(0,wire.sent!!.clientTimeMs);assertEquals(0,wire.sent!!.roomProgressCount);assertEquals(1,wire.accepted.size)
    }
    @Test fun `page change during storage read drops old report and stale ack`()=runTest {
        val wire=wire()
        HeartbeatClient(wire) {wire.scope=wire.scope!!.copy(room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),generation=4);4}.send()
        assertEquals(0,wire.sent!!.roomProgressCount);assertTrue(wire.accepted.isEmpty())
    }
    @Test fun `reconnect during storage read never sends old progress on new socket`()=runTest {
        val wire=wire()
        assertFailsWith<RealtimeUnavailableBeforeAdmission> {
            HeartbeatClient(wire) {wire.authenticatedEpoch=2;wire.scope=wire.scope!!.copy(connectionEpoch=2);4}.send()
        }
        assertNull(wire.sent);assertTrue(wire.accepted.isEmpty())
    }
    @Test fun `late ack cannot wake replaced connection generation or ended scope`()=runTest {
        for(change in listOf<(Wire)->Unit>({it.scope=null},{it.scope=it.scope!!.copy(generation=4)},
            {it.authenticatedEpoch=2;it.scope=it.scope!!.copy(connectionEpoch=2)})) {
            val wire=wire();wire.beforeReply={change(wire)}
            HeartbeatClient(wire) {4}.send();assertTrue(wire.accepted.isEmpty())
        }
    }
    @Test fun `not ready observation is ignored and no scope never reads a cursor`()=runTest {
        val wire=wire();wire.result=ack(wire.result.heartbeatAck.getRoomSubscriptionStates(0).toBuilder().setReady(false).build())
        HeartbeatClient(wire) {4}.send();assertTrue(wire.accepted.isEmpty())
        wire.scope=null;HeartbeatClient(wire) {error("No installed scope")}.send();assertEquals(0,wire.sent!!.roomProgressCount)
    }
    @Test fun `malformed acknowledgments and nonpersistent cursor are rejected`()=runTest {
        val wire=wire();val state=wire.result.heartbeatAck.getRoomSubscriptionStates(0)
        for(result in listOf(Envelope.getDefaultInstance(),ack(state,state),ack(state.toBuilder().setRoomId("bad").build()),
            ack(state.toBuilder().setScopeGeneration(0).build()),ack(state.toBuilder().setHighWatermark(-1).build()),
            ack(state.toBuilder().setAppliedRoomSequence(-1).build()),ack(state.toBuilder().setAppliedRoomSequence(21).build()))) {
            wire.result=result;assertFailsWith<ClientFailure.Protocol> {HeartbeatClient(wire).send()};assertTrue(wire.accepted.isEmpty())
        }
        assertFailsWith<ClientFailure.Protocol> {HeartbeatClient(wire) {-1}.send()}
    }
    private fun coverage(id: RoomId=room,revision: Long=1,generation: Long=1,head: Long=10,state: ActivityCoverageState=ActivityCoverageState.Ready)=
        RealtimeSyncHint.Coverage(SyncCoverageScope.Room,id.value,revision,generation,head,state,
            when(state) {ActivityCoverageState.Ready->SyncCoverageReason.Confirmed;ActivityCoverageState.Ended->SyncCoverageReason.Cancelled;else->SyncCoverageReason.Lost})
    @Test fun `coverage revisions span room identities and ended generation cannot be resurrected`() {
        val tracker=SyncCoverageTracker();val other=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        assertTrue(tracker.accept(coverage()));assertEquals(room,tracker.room(1)!!.room)
        assertTrue(tracker.accept(coverage(other,2,2)));assertEquals(other,tracker.room(1)!!.room)
        assertFalse(tracker.accept(coverage(revision=1,generation=3)))
        assertFalse(tracker.accept(coverage(revision=3,generation=1)))
        assertTrue(tracker.accept(coverage(other,3,2,state=ActivityCoverageState.Ended)));assertNull(tracker.room(1))
        assertFalse(tracker.accept(coverage(other,4,2)))
        assertTrue(tracker.accept(coverage(revision=5,generation=3)));assertEquals(room,tracker.room(1)!!.room)
        tracker.clear();assertTrue(tracker.accept(coverage()));assertEquals(2,tracker.room(2)!!.connectionEpoch)
    }
    @Test fun `ready baseline is immutable and recovering is not installed`() {
        val tracker=SyncCoverageTracker();tracker.accept(coverage())
        assertFailsWith<ClientFailure.Protocol> {tracker.accept(coverage(revision=2,head=11))}
        assertEquals(10,tracker.room(1)!!.baselineHead)
        assertTrue(tracker.accept(coverage(revision=2,state=ActivityCoverageState.Recovering)));assertNull(tracker.room(1))
        assertTrue(tracker.accept(coverage(revision=3)));assertEquals(10,tracker.room(1)!!.baselineHead)
    }
}
