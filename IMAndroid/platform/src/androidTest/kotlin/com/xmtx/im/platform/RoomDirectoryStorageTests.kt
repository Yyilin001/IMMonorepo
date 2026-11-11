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

class RoomDirectoryStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun entry(room: RoomId=this.room)=RoomDirectoryEntry(room,RoomKind.Group,3,2)
    private fun page(next: String="",topology: String="t",vararg entries: RoomDirectoryEntry)=RoomDirectoryPage(entries.toList().toPersistentList(),next,topology)
    private suspend fun seed(s: SqliteClientStore) {
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("ready").setSyncReceipt("receipt").build(),s.cursor())
    }
    private suspend fun grant(s: SqliteClientStore,revision: Long=1,member: Boolean=true,valid: Boolean=true) {
        val cursor=s.cursor()
        val payload="""{"event_type":"membership_changed","room_id":"${room.value}","membership_revision":$revision,"target_user_id":"${actor.value}","action":"${if(member)"add" else "remove"}"${if(valid)",\"title\":\"群聊\"" else ""}}"""
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("grant").setSyncReceipt("receipt")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(cursor.sequence+1).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("membership").setPayload(ByteString.copyFromUtf8(payload))).build(),cursor)
        s.acknowledged(s.cursor())
    }
    @Test fun directoryPageAndWorkSurviveReopenWithoutGrantingAccessAndOldConnectionCannotCommit()=runBlocking<Unit> {
        var s=store();try {
            seed(s);val oldScope=s.beginDirectory();val request=s.directoryScan(oldScope)
            s.commitDirectoryPage(request,page("next","t",entry()))
            assertEquals(1,s.directoryProgress(oldScope).pendingRooms);assertTrue(s.snapshot().conversations.isEmpty())
            s.close();s=store();val scope=s.beginDirectory();assertNotEquals(oldScope,scope)
            assertEquals("next",s.directoryScan(scope).cursor);assertEquals(1,s.directoryWork(scope,0,16).size)
            assertTrue(runCatching {s.commitDirectoryPage(request,page())}.exceptionOrNull() is RoomDirectoryFailure)
            s.commitDirectoryPage(s.directoryScan(scope),page())
            assertTrue(s.directoryProgress(scope).complete);assertEquals(1,s.directoryProgress(scope).pendingRooms)
            assertNull(s.recoveryCandidate(scope))
        } finally {s.close()}
    }
    @Test fun topologyChangeAndCursorCycleRollbackAndRestartPreservesQueuedRooms()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),page("a","t",entry()))
            val a=s.directoryScan(scope)
            assertTrue(runCatching {s.commitDirectoryPage(a,page("b","new"))}.exceptionOrNull() is RoomDirectoryFailure)
            assertEquals(a,s.directoryScan(scope));assertEquals(1,s.directoryProgress(scope).pendingRooms)
            s.commitDirectoryPage(a,page("b")) // Filtered empty page still advances.
            assertTrue(runCatching {s.commitDirectoryPage(s.directoryScan(scope),page("a"))}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals("b",s.directoryScan(scope).cursor)
            s.restartDirectory(scope);assertEquals("",s.directoryScan(scope).cursor);assertEquals(1,s.directoryProgress(scope).pendingRooms)
            assertTrue(runCatching {s.commitDirectoryPage(a,page())}.exceptionOrNull() is RoomDirectoryFailure)
        } finally {s.close()}
    }
    @Test fun snapshotGenerationInvalidatesOutstandingPageAndCompletedCandidate()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();val request=s.directoryScan(scope)
            s.commitDirectoryPage(request,page());val candidate=requireNotNull(s.recoveryCandidate(scope))
            s.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(0).setNextSyncToken("snapshot").build(),persistentListOf())
            assertFalse(s.directoryScan(scope).complete);assertNotEquals(request.round,s.directoryScan(scope).round)
            assertFalse(s.verifyRecoveryCandidate(candidate,s.cursor()))
            assertTrue(runCatching {s.commitDirectoryPage(request,page())}.exceptionOrNull() is RoomDirectoryFailure)
        } finally {s.close()}
    }
    @Test fun refreshedWorkRevisionCannotBeCompletedByOldRequestOrBypassedThroughRetryAndColdRoomsRunFirst()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();val other=RoomId(UUID.randomUUID().toString())
            s.commitDirectoryPage(s.directoryScan(scope),page("next","t",entry(),entry(other)))
            val selected=s.directoryWork(scope,0,16).first {it.room==room}
            assertEquals(3L,selected.minimumMembership);assertEquals(2L,selected.minimumOwner)
            s.finishDirectoryWork(scope,selected,2_000)
            assertEquals(other,s.directoryWork(scope,1_000,16).single().room)
            s.commitDirectoryPage(s.directoryScan(scope),page("","t",entry()))
            s.finishDirectoryWork(scope,selected,null)
            assertEquals(2,s.directoryProgress(scope).pendingRooms);assertEquals(other,s.directoryWork(scope,1_000,16).single().room)
            s.finishDirectoryWork(scope,selected,3_000) // The old response can defer, but cannot erase, refreshed work.
            assertEquals(other,s.directoryWork(scope,2_000,16).single().room)
            val due=s.directoryWork(scope,3_000,16);assertEquals(other,due.first().room);assertNotEquals(selected.revision,due.last().revision)
        } finally {s.close()}
    }
    @Test fun personalGrantAfterCompletedDirectoryRetainsWorkAndRevocationRemovesItAtomically()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),page())
            assertNotNull(s.recoveryCandidate(scope))
            assertTrue(runCatching {grant(s,valid=false)}.isFailure);assertEquals(0,s.directoryProgress(scope).pendingRooms);assertEquals(0L,s.cursor().sequence)
            grant(s);assertEquals(room,s.directoryWork(scope,0,16).single().room);assertNull(s.recoveryCandidate(scope))
            grant(s,2,false);assertEquals(0,s.directoryProgress(scope).pendingRooms);assertTrue(s.snapshot().conversations.isEmpty())
        } finally {s.close()}
    }
    @Test fun candidateRequiresExactAcknowledgedPersonalCheckpointAndNoPendingSnapshotOrHead()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),page())
            val candidate=requireNotNull(s.recoveryCandidate(scope));val checkpoint=s.cursor()
            assertTrue(s.verifyRecoveryCandidate(candidate,checkpoint))
            s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("later").setSyncReceipt("receipt").build(),checkpoint)
            assertFalse(s.verifyRecoveryCandidate(candidate,checkpoint))
            s.stage(SnapshotManifest.newBuilder().setSnapshotId("pending").setGeneration(2).build());assertNull(s.recoveryCandidate(scope))
            assertFalse(s.verifyRecoveryCandidate(candidate,s.cursor()))
        } finally {s.close()}
    }
    @Test fun pendingPersonalRoomHeadBlocksCompletionUntilAuthorizedRoomCursorCatchesUp()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),page())
            val candidate=requireNotNull(s.recoveryCandidate(scope))
            val payload="""{"room_id":"${room.value}","room_sequence":5,"membership_revision":1}"""
            s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("head").setSyncReceipt("receipt")
                .addRecords(SyncRecord.newBuilder().setUserSyncSequence(1).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("room_head").setPayload(ByteString.copyFromUtf8(payload))).build(),s.cursor())
            assertNull(s.recoveryCandidate(scope));s.acknowledged(s.cursor());assertNull(s.recoveryCandidate(scope))
            assertFalse(s.verifyRecoveryCandidate(candidate,s.cursor()))
            s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(5).setUnreadCount(5).setViewerMembershipRevision(1).setOwnerEpoch(1).build())
            s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(5).build(),RoomCursor())
            assertTrue(s.verifyRecoveryCandidate(candidate,s.cursor()))
        } finally {s.close()}
    }
    @Test fun paginatedDiscoveryDoesNotRevokeRoomsAbsentFromPartialOrCompletedPage()=runBlocking<Unit> {
        val s=store();try {
            seed(s);grant(s);val scope=s.beginDirectory()
            s.commitDirectoryPage(s.directoryScan(scope),page("next"));assertTrue(s.snapshot().conversations.any {it.id==room})
            s.commitDirectoryPage(s.directoryScan(scope),page());assertTrue(s.snapshot().conversations.any {it.id==room})
            val old=s.directoryWork(scope,0,16).single();s.finishDirectoryWork(scope,old,null)
            grant(s,2);assertEquals(1,s.directoryProgress(scope).pendingRooms)
        } finally {s.close()}
    }
}
