package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class RecoveryBatchStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val a=RoomId(UUID.randomUUID().toString());private val b=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun state(room: RoomId,revision: Long=1)=RoomSyncState.newBuilder().setRoomId(room.value).setOwnerEpoch(1).setViewerMembershipRevision(revision).setHead(5).setUnreadCount(5).build()
    private suspend fun setup(s: SqliteClientStore): String {
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("seed").setSyncReceipt("receipt").build(),s.cursor())
        val scope=s.beginDirectory();s.commitDirectoryPage(s.directoryScan(scope),RoomDirectoryPage(listOf(a,b).map {RoomDirectoryEntry(it,RoomKind.Group,1,1)}.toPersistentList(),"","t"))
        s.acceptStates(persistentMapOf(a to state(a),b to state(b)));return scope
    }
    @Test fun authorityBatchRollsBackEarlierRoomWhenLaterLocalMembershipRejectsState()=runBlocking<Unit> {
        val s=store();try {
            s.acceptState(b,state(b,5))
            assertTrue(runCatching {s.acceptStates(linkedMapOf(a to state(a),b to state(b,4)).toPersistentMap())}.exceptionOrNull() is ClientFailure.Protocol)
            assertTrue(s.snapshot().conversations.none {it.id==a});assertEquals(listOf(b),s.snapshot().conversations.map {it.id})
            assertEquals(RoomCursor(),s.roomCursor(a));assertTrue(s.snapshot().messages.isEmpty())
        } finally {s.close()}
    }
    @Test fun successfulBatchInstallsBothAuthoritiesWithoutContentOrCursorProgress()=runBlocking<Unit> {
        val s=store();try {
            setup(s);assertEquals(setOf(a,b),s.snapshot().conversations.map {it.id}.toSet())
            assertTrue(s.snapshot().messages.isEmpty());assertEquals(RoomCursor(),s.roomCursor(a));assertEquals(RoomCursor(),s.roomCursor(b))
            assertTrue(s.snapshot().conversations.all {it.unread==5})
        } finally {s.close()}
    }
    @Test fun invalidLaterSummaryRollsBackEarlierCacheAndWorkUpdates()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val works=s.directoryWork(scope,0,16).associateBy {it.room};val request=s.beginLatestVisible(scope)
            val valid=LatestVisibleCommit(works.getValue(a),LatestVisibleSnapshot(a,1,1,5,null))
            val invalid=LatestVisibleCommit(works.getValue(b),LatestVisibleSnapshot(b,-1,1,5,null))
            assertTrue(runCatching {s.commitLatestVisibleBatch(request,persistentListOf(valid,invalid))}.exceptionOrNull() is ClientFailure.Protocol)
            assertTrue(s.snapshot().conversations.all {it.preview.isEmpty()});assertTrue(s.directoryWork(scope,0,16).all {it.requiresSummary && it.targetHead==0L})
            assertEquals(setOf(a,b),s.commitLatestVisibleBatch(request,persistentListOf(valid,invalid.copy(snapshot=invalid.snapshot.copy(owner=1)))))
            assertTrue(s.snapshot().conversations.all {it.preview=="暂无消息"})
        } finally {s.close()}
    }
    @Test fun staleSummaryIsIndependentlyRejectedWhileValidSiblingRemainsDisplayOnly()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val works=s.directoryWork(scope,0,16).associateBy {it.room}
            val entries=persistentListOf(LatestVisibleCommit(works.getValue(a),LatestVisibleSnapshot(a,1,1,5,null)),LatestVisibleCommit(works.getValue(b),LatestVisibleSnapshot(b,1,1,4,null)))
            assertEquals(setOf(a),s.commitLatestVisibleBatch(s.beginLatestVisible(scope),entries))
            assertEquals("暂无消息",s.snapshot().conversations.single {it.id==a}.preview);assertEquals("",s.snapshot().conversations.single {it.id==b}.preview)
            assertTrue(s.directoryWork(scope,0,16).single {it.room==b}.requiresSummary);assertEquals(2,s.directoryProgress(scope).pendingRooms)
            assertEquals(RoomCursor(),s.roomCursor(a));assertNull(s.recoveryCandidate(scope))
        } finally {s.close()}
    }
    @Test fun duplicateRoomsOldConnectionAndChangedGenerationCannotCommitBatch()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val request=s.beginLatestVisible(scope);val work=s.directoryWork(scope,0,16).first()
            val entry=LatestVisibleCommit(work,LatestVisibleSnapshot(work.room,1,1,5,null))
            assertTrue(runCatching {s.commitLatestVisibleBatch(request,persistentListOf(entry,entry))}.exceptionOrNull() is IllegalArgumentException)
            val next=s.beginDirectory();assertTrue(runCatching {s.commitLatestVisibleBatch(request,persistentListOf(entry))}.exceptionOrNull() is RoomDirectoryFailure)
            val current=s.beginLatestVisible(next)
            s.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setNextSyncToken("new").build(),persistentListOf())
            assertTrue(s.commitLatestVisibleBatch(current,persistentListOf(entry)).isEmpty());assertTrue(s.snapshot().conversations.isEmpty())
        } finally {s.close()}
    }
}
