package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentMap
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class RoomRecoveryTests {
    private class Store : RoomStore {
        var cursor=RoomCursor();var revoked=false;var failCommit=false;var accepted=false
        override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId,RoomKind>) {error("Target recovery must not scan the full directory")}
        override suspend fun acceptStates(states: kotlinx.collections.immutable.PersistentMap<RoomId,RoomSyncState>) {states.forEach {(room,state) -> acceptState(room,state)}}
        override suspend fun acceptState(room: RoomId,state: RoomSyncState) {accepted=true}
        override suspend fun unavailable(room: RoomId) {revoked=true}
        override suspend fun roomCursor(room: RoomId)=cursor
        override suspend fun commitRoom(page: GroupEventPage,expected: RoomCursor) {
            assertTrue(accepted);assertEquals(cursor,expected)
            if(failCommit) throw IOException()
            cursor=RoomCursor(page.nextRoomSequence)
        }
    }
    private class Wire(val store: Store) : EnvelopeTransport {
        val calls=mutableListOf<Envelope>();var retry=0;var unavailable=false;var invalidState=false;var forbidPull=false
        override suspend fun request(body: Envelope.Builder): Envelope {
            val request=body.build();calls+=request
            return when {
                request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder()
                    .addRooms(RoomSyncStateResult.newBuilder().setRoomId("room").apply {
                        when {
                            this@Wire.unavailable -> setUnavailable(RoomSyncStateUnavailable.getDefaultInstance())
                            this@Wire.retry>0 -> setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(this@Wire.retry))
                            else -> setState(RoomSyncState.newBuilder().setRoomId("room").setHead(5).setUnreadCount(if(invalidState)4 else 5))
                        }
                    })).build()
                request.hasGroupEventPull() -> {
                    if(forbidPull) throw GatewayFailure("FORBIDDEN",false,0)
                    val next=request.groupEventPull.afterRoomSequence+1
                    Envelope.newBuilder().setGroupEventPage(GroupEventPage.newBuilder().setRoomId("room").setNextRoomSequence(next).setHasMore(next<5)).build()
                }
                request.hasDeviceRoomProgressReport() -> {
                    assertEquals(store.cursor.sequence,request.deviceRoomProgressReport.getRooms(0).appliedThrough)
                    Envelope.newBuilder().setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList)).build()
                }
                else -> error("Unexpected command")
            }
        }
    }
    @Test fun `target recovery yields at page budget then resumes committed delivery cursor`()=runTest {
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store,{-5_000_000_000});val room=RoomId("room")
        val first=engine.synchronizeRoom(room,2)
        assertEquals(RoomRecoveryResult(room,2,5,true),first)
        assertEquals(2,wire.calls.count {it.hasGroupEventPull()});assertEquals(2,wire.calls.count {it.hasDeviceRoomProgressReport()})
        assertTrue(engine.synchronizeRoom(room,2).hasMore)
        val last=engine.synchronizeRoom(room,2);assertFalse(last.hasMore);assertEquals(5,last.appliedThrough)
        assertEquals(3,wire.calls.count {it.hasRoomSyncStateBatch()})
    }
    @Test fun `server retry and unavailable state cannot pull or acknowledge messages`()=runTest {
        var now=0L
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store,{now});val room=RoomId("room")
        wire.retry=3;assertEquals(3_000,engine.synchronizeRoom(room).retryAfterMillis)
        now=1_000_000_000;assertEquals(2_000,engine.synchronizeRoom(room).retryAfterMillis)
        assertEquals(1,wire.calls.size)
        now=3_000_000_000;wire.retry=0;wire.unavailable=true;assertTrue(engine.synchronizeRoom(room).unavailable);assertTrue(store.revoked)
        assertFalse(wire.calls.any {it.hasGroupEventPull() || it.hasDeviceRoomProgressReport()})
    }
    @Test fun `invalid authority and failed local commit never report progress`()=runTest {
        val store=Store();val wire=Wire(store);val engine=RoomSyncEngine(wire,store)
        wire.invalidState=true;assertFailsWith<ClientFailure.Protocol> {engine.synchronizeRoom(RoomId("room"))}
        assertFalse(store.accepted)
        wire.invalidState=false;store.failCommit=true;assertFailsWith<IOException> {engine.synchronizeRoom(RoomId("room"))}
        assertEquals(0,store.cursor.sequence);assertFalse(wire.calls.any {it.hasDeviceRoomProgressReport()})
    }
    @Test fun `membership lost between authority and pull revokes local scope without acknowledging`()=runTest {
        val store=Store();val wire=Wire(store).apply {forbidPull=true}
        assertTrue(RoomSyncEngine(wire,store).synchronizeRoom(RoomId("room")).unavailable)
        assertTrue(store.revoked);assertFalse(wire.calls.any {it.hasDeviceRoomProgressReport()})
    }
}
