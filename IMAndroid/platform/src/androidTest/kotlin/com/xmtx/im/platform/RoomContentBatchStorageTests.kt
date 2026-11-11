package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class RoomContentBatchStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val a=RoomId(UUID.randomUUID().toString());private val b=RoomId(UUID.randomUUID().toString())
    private fun store(device: DeviceId=this.device)=SqliteClientStore(context,actor,device)
    private fun state(room: RoomId,owner: Long=1,member: Long=1)=RoomSyncState.newBuilder().setRoomId(room.value)
        .setOwnerEpoch(owner).setViewerMembershipRevision(member).setHead(50).setUnreadCount(50).build()
    private suspend fun setup(s: SqliteClientStore): String {
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("seed").setSyncReceipt("receipt").build(),s.cursor())
        val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),RoomDirectoryPage(listOf(a,b).map {RoomDirectoryEntry(it,RoomKind.Group,1,1)}.toPersistentList(),"","t"))
        s.acceptStates(persistentMapOf(a to state(a),b to state(b)));return scope
    }
    private suspend fun request(s: SqliteClientStore,scope: String)=s.beginRoomContent(scope,s.directoryWork(scope,0,16))
    private fun page(room: RoomId,next: Long=1)=GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(next).addEvents(GroupEvent.newBuilder()
        .setRoomSequence(next).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("message")
        .setPayload(ByteString.copyFromUtf8("""{"event_type":"message.accepted","message_id":"${UUID.randomUUID()}","room_id":"${room.value}","sender_user_id":"${actor.value}","text":"batch $next","room_sequence":$next,"message_revision":1,"server_created_at_ms":1}"""))).build()
    private fun response()=RoomContentResponse(persistentMapOf(a to page(a),b to page(b)),persistentSetOf())
    @Test fun twoRoomBodiesAndCursorsCommitAtomicallyAndSurviveReopen()=runBlocking<Unit> {
        var s=store();try {
            val scope=setup(s);val result=s.commitRoomContent(request(s,scope),response())
            assertEquals(mapOf(a to RoomCursor(1),b to RoomCursor(1)),result);assertEquals(2,s.snapshot().messages.size)
            s.close();s=store();assertEquals(2,s.snapshot().messages.size);assertEquals(RoomCursor(1),s.roomCursor(a));assertEquals(RoomCursor(1),s.roomCursor(b))
        } finally {s.close()}
    }
    @Test fun laterProjectionFailureRollsBackEarlierRoomAndAllCursors()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val first=page(a);val bad=page(b).toBuilder().clearEvents().addEvents(GroupEvent.newBuilder().setRoomSequence(1)
                .setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("membership").setPayload(ByteString.copyFromUtf8("""{"room_id":"${b.value}","event_type":"membership_changed"}"""))).build()
            val result=RoomContentResponse(linkedMapOf(a to first,b to bad).toPersistentMap(),persistentSetOf())
            assertTrue(runCatching {s.commitRoomContent(request(s,scope),result)}.exceptionOrNull() is ClientFailure.Protocol)
            assertTrue(s.snapshot().messages.isEmpty());assertEquals(RoomCursor(),s.roomCursor(a));assertEquals(RoomCursor(),s.roomCursor(b))
        } finally {s.close()}
    }
    @Test fun changedOwnerMembershipAndRejoinCannotAuthorizeOldBodiesOrOldDenial()=runBlocking<Unit> {
        for(mode in 0..2) {
            val s=store(DeviceId(UUID.randomUUID().toString()));try {
                val scope=setup(s);val old=request(s,scope)
                when(mode) {
                    0 -> s.acceptState(b,state(b,owner=2))
                    1 -> s.acceptState(b,state(b,member=2))
                    else -> {s.unavailable(b);s.acceptState(b,state(b,member=2))}
                }
                val result=RoomContentResponse(persistentMapOf(a to page(a)),persistentSetOf(b))
                assertTrue(runCatching {s.commitRoomContent(old,result)}.exceptionOrNull() is ClientFailure.Protocol)
                assertTrue(s.snapshot().messages.isEmpty());assertEquals(RoomCursor(),s.roomCursor(a));assertTrue(s.snapshot().conversations.any {it.id==b})
            } finally {s.close()}
        }
    }
    @Test fun changedCursorRejectsWholeBatchWithoutDuplicatingOrReorderingContent()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val old=request(s,scope);s.commitRoom(page(b),RoomCursor())
            assertTrue(runCatching {s.commitRoomContent(old,response())}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals(1,s.snapshot().messages.size);assertEquals(b,s.snapshot().messages.single().roomId);assertEquals(RoomCursor(),s.roomCursor(a))
        } finally {s.close()}
    }
    @Test fun connectionGenerationAndPendingSnapshotRejectOldNetworkResponses()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val old=request(s,scope);val next=s.beginDirectory()
            assertTrue(runCatching {s.commitRoomContent(old,response())}.exceptionOrNull() is RoomDirectoryFailure)
            val current=request(s,next)
            val manifest=SnapshotManifest.newBuilder().setGeneration(2).setSnapshotId("new").setNextSyncToken("new").build()
            s.stage(manifest)
            assertTrue(runCatching {s.commitRoomContent(current,response())}.exceptionOrNull() is ClientFailure.ResetRequired)
            s.activateFixture(manifest,persistentListOf())
            assertTrue(runCatching {s.commitRoomContent(current,response())}.exceptionOrNull() is ClientFailure.ResetRequired)
            assertTrue(s.snapshot().messages.isEmpty())
        } finally {s.close()}
    }
    @Test fun validDenialAndSiblingBodyCommitTogetherWithoutDenialCursor()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val result=s.commitRoomContent(request(s,scope),RoomContentResponse(persistentMapOf(a to page(a)),persistentSetOf(b)))
            assertEquals(mapOf(a to RoomCursor(1)),result);assertEquals(listOf(a),s.snapshot().conversations.map {it.id})
            assertEquals(RoomCursor(),s.roomCursor(b));assertTrue(s.directoryWork(scope,0,16).none {it.room==b})
        } finally {s.close()}
    }
    @Test fun emptyScannedPagesAdvanceAuthorizedCursorAndRetainHistoryTrimWhileMissingResultsFail()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val request=request(s,scope)
            assertTrue(runCatching {s.commitRoomContent(request,RoomContentResponse(persistentMapOf(a to page(a)),persistentSetOf()))}.exceptionOrNull() is IllegalArgumentException)
            val pages=listOf(a,b).associateWith {GroupEventPage.newBuilder().setRoomId(it.value).setNextRoomSequence(10).setLogTrimmedThroughRoomSequence(8).build()}.toPersistentMap()
            assertEquals(mapOf(a to RoomCursor(10,true),b to RoomCursor(10,true)),s.commitRoomContent(request,RoomContentResponse(pages,persistentSetOf())))
            assertTrue(s.snapshot().messages.isEmpty())
        } finally {s.close()}
    }
}
