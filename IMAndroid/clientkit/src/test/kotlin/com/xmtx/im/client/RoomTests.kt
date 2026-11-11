package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentMap
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class RoomTests {
    private fun event(sequence: Long, room: String = "room") = GroupEvent.newBuilder().setSourceEventId("e-$sequence").setRoomSequence(sequence)
        .setProjectionKind("message").setPayload(ByteString.copyFromUtf8("""{"room_id":"$room","room_sequence":$sequence}""")).build()
    @Test fun `authorized invisible gaps advance room cursor without assuming contiguity`() {
        val page = GroupEventPage.newBuilder().setRoomId("room").addEvents(event(5)).addEvents(event(9)).setNextRoomSequence(12).build()
        RoomSyncEngine.validatePage(RoomId("room"), RoomCursor(3), page)
        RoomSyncEngine.validatePage(RoomId("room"), RoomCursor(3), page.toBuilder().clearEvents().build())
    }
    @Test fun `wrong room out of order and stalled pages fail closed`() {
        val valid = GroupEventPage.newBuilder().setRoomId("room").addEvents(event(5)).setNextRoomSequence(5)
        listOf(valid.clone().setRoomId("other").build(), valid.clone().addEvents(event(4)).build(),
            valid.clone().clearEvents().setNextRoomSequence(3).setHasMore(true).build(),
            valid.clone().clearEvents().addEvents(event(5, "other")).build()).forEach {
            assertFailsWith<ClientFailure.Protocol> { RoomSyncEngine.validatePage(RoomId("room"), RoomCursor(3), it) }
        }
    }
    @Test fun `zero epoch room is valid but failed transaction never reports delivery progress`() = runTest {
        val store = object : RoomStore {
            override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId, RoomKind>) {}
            override suspend fun acceptStates(states: kotlinx.collections.immutable.PersistentMap<RoomId,RoomSyncState>) {states.forEach {(room,state) -> acceptState(room,state)}}
        override suspend fun acceptState(room: RoomId, state: RoomSyncState) {}
            override suspend fun unavailable(room: RoomId) {}
            override suspend fun roomCursor(room: RoomId) = RoomCursor()
            override suspend fun commitRoom(page: GroupEventPage, expected: RoomCursor) { throw IOException() }
        }
        val calls = mutableListOf<Envelope>()
        val transport = object : EnvelopeTransport {
            override suspend fun request(body: Envelope.Builder): Envelope {
                val request = body.build(); calls.add(request)
                return when {
                    request.hasUserRoomDirectoryList() -> Envelope.newBuilder().setUserRoomDirectoryPage(UserRoomDirectoryPage.newBuilder()
                        .setTopologyGeneration("topology").addRooms(UserRoomDirectoryEntry.newBuilder().setRoomId("room").setRoomKind("direct").setOwnerEpoch(0).setViewerMembershipRevision(0))).build()
                    request.hasRoomSyncStateBatch() -> Envelope.newBuilder().setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder()
                        .addRooms(RoomSyncStateResult.newBuilder().setRoomId("room").setState(RoomSyncState.newBuilder().setRoomId("room").setOwnerEpoch(0).setViewerMembershipRevision(0).setHead(5).setUnreadCount(5)))).build()
                    request.hasGroupEventPull() -> Envelope.newBuilder().setGroupEventPage(GroupEventPage.newBuilder().setRoomId("room").addEvents(event(5)).setNextRoomSequence(5)).build()
                    else -> error("delivery progress before commit")
                }
            }
        }
        assertFailsWith<IOException> { RoomSyncEngine(transport, store).synchronize() }
        assertFalse(calls.any { it.hasDeviceRoomProgressReport() })
    }
}
