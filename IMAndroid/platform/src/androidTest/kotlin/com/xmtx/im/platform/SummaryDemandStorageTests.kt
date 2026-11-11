package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class SummaryDemandStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val cold=RoomId("FFFFFFFF-0000-0000-0000-000000000001")
    private val hot=RoomId("00000000-0000-0000-0000-000000000001")
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun setup(s: SqliteClientStore): String {
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("seed").setSyncReceipt("receipt").build(),s.cursor())
        val scope=s.beginDirectory()
        s.commitDirectoryPage(s.directoryScan(scope),RoomDirectoryPage(persistentListOf(RoomDirectoryEntry(cold,RoomKind.Group,1,1),RoomDirectoryEntry(hot,RoomKind.Group,1,1)),"","topology"))
        return scope
    }
    @Test fun visibleDemandRaisesPriorityWithoutReplacingInFlightRevisionOrRetryAcrossReopen()=runBlocking<Unit> {
        var s=store();try {
            val scope=setup(s);val original=s.directoryWork(scope,0,16).first {it.room==hot}
            s.ensureLatestVisible(scope,persistentListOf(hot,hot));assertEquals(original.revision,s.directoryWork(scope,0,16).first().revision)
            assertEquals(hot,s.directoryWork(scope,0,16).first().room)
            assertEquals(cold,s.directoryWork(scope,0,16,true).first().room)
            s.finishDirectoryWork(scope,original,2_000);s.ensureLatestVisible(scope,persistentListOf(hot))
            assertEquals(cold,s.directoryWork(scope,1_999,16).single().room)
            s.close();s=store();val next=s.beginDirectory();s.ensureLatestVisible(next,persistentListOf(hot))
            assertEquals(cold,s.directoryWork(next,1_999,16).single().room)
            assertEquals(original.revision,s.directoryWork(next,2_000,16).first().revision)
        } finally {s.close()}
    }
    @Test fun newlyReinsertedHotRoomCannotJumpAheadOfOlderColdRoomInFairSelection()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s)
            repeat(6) {
                s.ensureLatestVisible(scope,persistentListOf(hot))
                val selected=s.directoryWork(scope,0,1).single();assertEquals(hot,selected.room)
                s.finishDirectoryWork(scope,selected,null)
                s.ensureLatestVisible(scope,persistentListOf(hot))
                assertEquals(cold,s.directoryWork(scope,0,1,true).single().room)
            }
        } finally {s.close()}
    }
    @Test fun staleSuccessfulResponsePreservesNewWorkButStillRecordsThatRoomWasServed()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);s.ensureLatestVisible(scope,persistentListOf(hot))
            val old=s.directoryWork(scope,0,1).single()
            s.restartDirectory(scope);s.commitDirectoryPage(s.directoryScan(scope),RoomDirectoryPage(persistentListOf(RoomDirectoryEntry(hot,RoomKind.Group,2,1)),"","new"))
            s.finishDirectoryWork(scope,old,null)
            val current=s.directoryWork(scope,0,16).first {it.room==hot};assertNotEquals(old.revision,current.revision)
            assertEquals(cold,s.directoryWork(scope,0,1,true).single().room)
        } finally {s.close()}
    }
    @Test fun validSummaryDoesNotCreateNewWorkAndRevokedRoomsCannotBeRequeuedByDisplayInterest()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s)
            s.acceptState(hot,RoomSyncState.newBuilder().setRoomId(hot.value).setOwnerEpoch(1).setViewerMembershipRevision(1).build())
            val work=s.directoryWork(scope,0,16).first {it.room==hot}
            assertTrue(s.commitLatestVisible(s.beginLatestVisible(scope),work,LatestVisibleSnapshot(hot,1,1,0,null)))
            s.finishDirectoryWork(scope,work,null)
            repeat(3) {s.ensureLatestVisible(scope,persistentListOf(hot))}
            assertEquals(listOf(cold),s.directoryWork(scope,0,16).map {it.room})
            s.unavailable(hot);s.ensureLatestVisible(scope,persistentListOf(hot))
            assertEquals(listOf(cold),s.directoryWork(scope,0,16).map {it.room})
            val other=s.beginDirectory()
            assertTrue(runCatching {s.ensureLatestVisible(scope,persistentListOf(hot))}.exceptionOrNull() is RoomDirectoryFailure)
            assertEquals(1,s.directoryProgress(other).pendingRooms)
        } finally {s.close()}
    }
}
