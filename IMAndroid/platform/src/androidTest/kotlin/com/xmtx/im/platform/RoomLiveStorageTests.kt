package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class RoomLiveStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun authorize(s: SqliteClientStore)=s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setOwnerEpoch(1)
        .setViewerMembershipRevision(1).setHead(600).setUnreadCount(600).build())
    private fun event(sequence: Long)=GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(UUID.randomUUID().toString())
        .setProjectionKind("message").setPayload(ByteString.copyFromUtf8("""{"event_type":"message.accepted","message_id":"m$sequence","room_id":"${room.value}","sender_user_id":"${actor.value}","text":"live $sequence","room_sequence":$sequence,"message_revision":1,"server_created_at_ms":1}""")).build()
    private fun page(vararg sequences: Long)=GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequences.last()).addAllEvents(sequences.map(::event)).build()
    @Test fun unknownAndRevokedRoomsCannotGainAccessFromLiveBodies()=runBlocking<Unit> {
        val s=store();try {
            assertFalse(s.commitLiveRoom(page(1),RoomCursor()));assertTrue(s.snapshot().messages.isEmpty())
            authorize(s);s.unavailable(room)
            assertFalse(s.commitLiveRoom(page(1),RoomCursor()));assertTrue(s.snapshot().messages.isEmpty());assertTrue(s.snapshot().conversations.isEmpty())
        } finally {s.close()}
    }
    @Test fun prefixAndCursorCommitTogetherSurviveReopenAndRejectStaleCAS()=runBlocking<Unit> {
        var s=store();try {
            authorize(s);assertTrue(s.commitLiveRoom(page(1,2),RoomCursor()));assertEquals(2L,s.roomCursor(room).sequence)
            assertEquals(2,s.snapshot().messages.size)
            s.close();s=store();assertEquals(2L,s.roomCursor(room).sequence);assertEquals(2,s.snapshot().messages.size)
            assertFalse(s.commitLiveRoom(page(1,2),RoomCursor()));assertEquals(2,s.snapshot().messages.size)
            assertTrue(s.commitLiveRoom(page(3),RoomCursor(2)));assertEquals(3L,s.roomCursor(room).sequence)
        } finally {s.close()}
    }
    @Test fun projectionFailureRollsBackEarlierMessageAndCursorInSameBatch()=runBlocking<Unit> {
        val s=store();try {
            authorize(s)
            val bad=event(2).toBuilder().setProjectionKind("membership").setPayload(ByteString.copyFromUtf8("""{"room_id":"${room.value}","event_type":"membership_changed"}"""))
            val batch=page(1).toBuilder().setNextRoomSequence(2).addEvents(bad).build()
            assertTrue(runCatching {s.commitLiveRoom(batch,RoomCursor())}.exceptionOrNull() is ClientFailure.Protocol)
            assertTrue(s.snapshot().messages.isEmpty());assertEquals(RoomCursor(),s.roomCursor(room))
            assertTrue(s.commitLiveRoom(page(1),RoomCursor()))
        } finally {s.close()}
    }
    @Test fun gapsWatermarkOnlyAndTrimHintsCannotAdvanceLiveCursor()=runBlocking<Unit> {
        val s=store();try {
            authorize(s)
            val invalid=listOf(page(2),page(1,3),page(1).toBuilder().setNextRoomSequence(9).build(),page(1).toBuilder().setLogTrimmedThroughRoomSequence(1).build(),
                GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(9).build())
            for(p in invalid) assertTrue(runCatching {s.commitLiveRoom(p,RoomCursor())}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals(RoomCursor(),s.roomCursor(room));assertTrue(s.snapshot().messages.isEmpty())
            s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(2).setLogTrimmedThroughRoomSequence(2).build(),RoomCursor())
            assertTrue(s.commitLiveRoom(page(3),RoomCursor(2,true)));assertEquals(RoomCursor(3,true),s.roomCursor(room))
        } finally {s.close()}
    }
    @Test fun maximumBatchCommitsThroughSharedProjectionWhileDurablePageLimitStaysBounded()=runBlocking<Unit> {
        val s=store();try {
            authorize(s);assertTrue(s.commitLiveRoom(page(*(1L..500).toList().toLongArray()),RoomCursor()))
            assertEquals(500L,s.roomCursor(room).sequence);assertEquals(500,s.snapshot().messages.size)
        } finally {s.close()}
    }
}
