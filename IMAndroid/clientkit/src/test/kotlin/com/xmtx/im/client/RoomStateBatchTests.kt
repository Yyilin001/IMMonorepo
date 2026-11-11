package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class RoomStateBatchTests {
    private val a=RoomId("a");private val b=RoomId("b");private val c=RoomId("c")
    private class Store: RoomStore {
        val accepted=mutableListOf<PersistentMap<RoomId,RoomSyncState>>();val denied=mutableListOf<RoomId>();var fail=false
        override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId,RoomKind>)=error("No directory")
        override suspend fun acceptState(room: RoomId,state: RoomSyncState)=error("Must use atomic state batch")
        override suspend fun acceptStates(states: PersistentMap<RoomId,RoomSyncState>) {if(fail) throw IOException();accepted+=states}
        override suspend fun unavailable(room: RoomId) {denied+=room}
        override suspend fun roomCursor(room: RoomId)=RoomCursor()
        override suspend fun commitRoom(page: GroupEventPage,expected: RoomCursor)=error("Observation must not commit content")
    }
    private class Wire(var response: Envelope): EnvelopeTransport {
        val calls=mutableListOf<Envelope>()
        override suspend fun request(body: Envelope.Builder): Envelope {val request=body.build();assertTrue(request.hasRoomSyncStateBatch());calls+=request;return response}
    }
    private fun state(room: RoomId)=RoomSyncStateResult.newBuilder().setRoomId(room.value).setState(RoomSyncState.newBuilder().setRoomId(room.value).setHead(3).setUnreadCount(3).setOwnerEpoch(1).setViewerMembershipRevision(2))
    private fun response(vararg entries: RoomSyncStateResult.Builder)=Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addAllRooms(entries.map {it.build()})).build()
    @Test fun `one batch preserves authorized retry and unavailable results without pulling or acknowledging`()=runTest {
        val store=Store();val wire=Wire(response(state(a),RoomSyncStateResult.newBuilder().setRoomId(b.value).setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(2)),
            RoomSyncStateResult.newBuilder().setRoomId(c.value).setUnavailable(RoomSyncStateUnavailable.getDefaultInstance())))
        val engine=RoomSyncEngine(wire,store,{0})
        val result=engine.observeRooms(persistentListOf(a,b,c,a))
        assertEquals(3,wire.calls.single().roomSyncStateBatch.roomIdsCount);assertEquals(setOf(a),store.accepted.single().keys);assertEquals(listOf(c),store.denied)
        assertEquals(0,result.getValue(a).appliedThrough);assertEquals(3,result.getValue(a).observedHead);assertTrue(result.getValue(a).hasMore)
        assertEquals(2_000,result.getValue(b).retryAfterMillis);assertTrue(result.getValue(c).unavailable)
        wire.response=response(state(a),state(c));engine.observeRooms(persistentListOf(a,b,c))
        assertEquals(setOf(a.value,c.value),wire.calls.last().roomSyncStateBatch.roomIdsList.toSet())
    }
    @Test fun `malformed batch is fully rejected before any earlier entry changes local authority`()=runTest {
        val invalid=listOf(response(state(a)),response(state(a),state(a)),response(state(a),state(c)),
            response(state(a),state(b).setState(RoomSyncState.newBuilder().setRoomId(b.value).setHead(3).setUnreadCount(2))),
            response(state(a),RoomSyncStateResult.newBuilder().setRoomId(b.value)))
        for(reply in invalid) {
            val store=Store();val wire=Wire(reply)
            assertFailsWith<ClientFailure.Protocol> {RoomSyncEngine(wire,store).observeRooms(persistentListOf(a,b))}
            assertTrue(store.accepted.isEmpty());assertTrue(store.denied.isEmpty())
        }
    }
    @Test fun `failed atomic persistence does not apply sibling denial or issue delivery progress`()=runTest {
        val store=Store().apply {fail=true};val wire=Wire(response(state(a),RoomSyncStateResult.newBuilder().setRoomId(b.value).setUnavailable(RoomSyncStateUnavailable.getDefaultInstance())))
        assertFailsWith<IOException> {RoomSyncEngine(wire,store).observeRooms(persistentListOf(a,b))}
        assertEquals(1,wire.calls.size);assertTrue(store.accepted.isEmpty());assertTrue(store.denied.isEmpty())
    }
    @Test fun `full unsigned retry interval and all cooling batch do not overflow or hit network again`()=runTest {
        val store=Store();val wire=Wire(response(RoomSyncStateResult.newBuilder().setRoomId(a.value).setRetry(RoomSyncStateRetry.newBuilder().setRetryAfterSeconds(-1))))
        var now=0L;val engine=RoomSyncEngine(wire,store,{now})
        assertEquals(4_294_967_295_000L,engine.observeRooms(persistentListOf(a)).getValue(a).retryAfterMillis)
        now=1_000_000_000
        assertEquals(4_294_967_294_000L,engine.observeRooms(persistentListOf(a)).getValue(a).retryAfterMillis);assertEquals(1,wire.calls.size)
    }
}
