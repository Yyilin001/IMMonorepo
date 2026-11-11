package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class AccountRoomHeadStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun payload(room: RoomId=this.room,head: Long=10,membership: Long=1)=ByteString.copyFromUtf8("""{"room_id":"${room.value}","room_sequence":$head,"membership_revision":$membership}""")
    private suspend fun commit(store: SqliteClientStore,head: Long=10,membership: Long=1,room: RoomId=this.room) {
        val cursor=store.cursor()
        store.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("token").setSyncReceipt("receipt").setCapabilityProfile("base")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(cursor.sequence+1).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("room_head")
                .setPayload(payload(room,head,membership))).build(),cursor)
    }
    private suspend fun authorize(store: SqliteClientStore,revision: Long=1) = store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value)
        .setOwnerEpoch(1).setViewerMembershipRevision(revision).setHead(20).setUnreadCount(20).build())
    private fun database(block: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    @Test fun personalCommitRetainsRecoveryAcrossReopenWithoutGrantingRoomOrMessageAccess()=runBlocking<Unit> {
        var s=store();try {
            commit(s);assertEquals(1L,s.cursor().sequence);assertEquals("receipt",s.cursor().pendingReceipt)
            assertTrue(s.snapshot().conversations.isEmpty());assertTrue(s.snapshot().messages.isEmpty());assertEquals(0L,s.roomCursor(room).sequence)
            s.close();s=store();assertEquals(AccountRoomHead(room,10,1),s.pendingRoomHeads().single())
            authorize(s)
            s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(10).build(),RoomCursor())
            assertTrue(s.pendingRoomHeads().isEmpty())
        } finally {s.close()}
    }
    @Test fun conflictingHeadRollsBackPersonalCursorWhileReorderedOlderHeadIsIgnored()=runBlocking<Unit> {
        val s=store();try {
            commit(s);val cursor=s.cursor()
            assertTrue(runCatching {commit(s,10,2)}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals(cursor,s.cursor());assertEquals(AccountRoomHead(room,10,1),s.pendingRoomHeads().single())
            commit(s,9,2);assertEquals(2L,s.cursor().sequence);assertEquals(10L,s.pendingRoomHeads().single().sequence)
            commit(s,11,2);assertEquals(AccountRoomHead(room,11,2),s.pendingRoomHeads().single())
            assertTrue(runCatching {commit(s,12,1)}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals(3L,s.cursor().sequence)
        } finally {s.close()}
    }
    @Test fun deniedRoomIsNotRescheduledUntilFreshAuthorizationAndHeadsCannotUndoDenial()=runBlocking<Unit> {
        val s=store();try {
            commit(s);s.unavailable(room);assertTrue(s.pendingRoomHeads().isEmpty())
            commit(s,11,2);assertTrue(s.pendingRoomHeads().isEmpty());assertTrue(s.snapshot().conversations.isEmpty())
            authorize(s,2);assertEquals(11L,s.pendingRoomHeads().single().sequence)
        } finally {s.close()}
    }
    @Test fun snapshotValidationRollsBackAndActivationAtomicallyReplacesRetainedHeads()=runBlocking<Unit> {
        val s=store();try {
            commit(s)
            val items=persistentListOf(SnapshotItem("room_head",room.value,"head",1,payload(head=20,membership=2)))
            s.validateSnapshot(items);assertEquals(10L,s.pendingRoomHeads().single().sequence)
            val manifest=SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(9).setNextSyncToken("snapshot").build()
            s.activateFixture(manifest,items);assertEquals(AccountRoomHead(room,20,2),s.pendingRoomHeads().single());assertEquals(2L,s.cursor().generation)
            s.activateFixture(manifest,persistentListOf());assertTrue(s.pendingRoomHeads().isEmpty())
        } finally {s.close()}
    }
    @Test fun legacyRecordMigrationRetainsHighestHeadAndDoesNotRunAgainAfterRestart()=runBlocking<Unit> {
        var s=store();s.close()
        database {db ->
            db.execSQL("DROP TABLE account_room_heads");db.execSQL("DELETE FROM projection_migrations WHERE name='account_room_heads_v1'")
            for(head in listOf(12L,7L)) db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf("legacy-$head","room_head",payload(head=head).toByteArray(),room.value))
        }
        try {
            s=store();assertEquals(12L,s.pendingRoomHeads().single().sequence);s.unavailable(room);s.close();s=store()
            assertTrue(s.pendingRoomHeads().isEmpty())
            database {db ->assertEquals(0L,db.compileStatement("SELECT COUNT(*) FROM records WHERE kind='room_head'").use {it.simpleQueryForLong()})}
        } finally {s.close()}
    }
    @Test fun pendingScanWrapsWithoutLosingDeferredRoomsAndRespectsLimit()=runBlocking<Unit> {
        val s=store();try {
            val ids=(1..5).map {RoomId("00000000-0000-0000-0000-${it.toString().padStart(12,'0')}")}
            for(id in ids) commit(s,room=id)
            val first=s.pendingRoomHeads(limit=2);assertEquals(ids.take(2),first.map {it.room})
            val second=s.pendingRoomHeads(first.last().room,2);assertEquals(ids.drop(2).take(2),second.map {it.room})
            assertEquals(ids.take(2),s.pendingRoomHeads(ids.last(),2).map {it.room})
            s.unavailable(ids.first());assertEquals(ids[1],s.pendingRoomHeads().first().room)
        } finally {s.close()}
    }
}
