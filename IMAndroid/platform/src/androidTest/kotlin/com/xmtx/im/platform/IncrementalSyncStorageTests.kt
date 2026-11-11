package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class IncrementalSyncStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun sha(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString()); val peer = UserId(UUID.randomUUID().toString())
        val file = File(context.noBackupFilesDir,"im-${sha("${user.value}/${device.value}")}.db")
        var store = SqliteClientStore(context,user,device)
        val reset = SyncReset(UUID.randomUUID().toString(),2,10,123456)
        fun reopen() { store.close(); store = SqliteClientStore(context,user,device) }
        fun database(body: (SQLiteDatabase) -> Unit) { SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE).use(body) }
        fun manifest() = SnapshotManifest.newBuilder().setSnapshotId(reset.snapshotId).setGeneration(2).setBaseUserSyncSequence(10)
            .setSchemaVersion(31).setCapabilityProfile("base").setRootDigest(sha("IM-SNAPSHOT-V3\u000031\u000010\u0000base"))
            .setNextSyncToken("restored").setSyncReceipt("snapshot-receipt").build()
        fun batch(sequence: Long) = SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("old-token").setSyncReceipt("exact-receipt")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("event-$sequence").setProjectionKind("user_block")
                .setPayload(ByteString.copyFromUtf8("""{"target_user_id":"${peer.value}","is_blocked":true,"updated_at_ms":$sequence}"""))).build()
        fun resetResponse() = Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId(reset.snapshotId)
            .setGeneration(reset.generation).setBaseUserSyncSequence(reset.baseSequence).setExpiresAtMs(reset.expiresAtMillis)).build()
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
    }
    private fun fixture(body: suspend Fixture.() -> Unit) = runBlocking { val value=Fixture(); try { value.body() } finally { value.close() } }
    private fun wire(handler: suspend (Envelope) -> Envelope) = object : EnvelopeTransport {
        override suspend fun request(body: Envelope.Builder) = handler(body.build())
    }
    private fun ack() = Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private suspend fun fails(type: Class<out Throwable>, body: suspend () -> Unit) {
        try { body(); fail("Expected ${type.simpleName}") } catch(error: Throwable) { if(!type.isInstance(error)) throw error }
    }
    @Test fun boundedResetSurvivesReopenAndForegroundRestoresExactIdentityWithoutOldTokenPull() = fixture {
        store.commit(batch(1),store.cursor()); store.acknowledged(store.cursor())
        val pending=MessageCommand.text(user,RoomId(UUID.randomUUID().toString()),"pending",1000);store.enqueue(pending)
        val result=SyncEngine(wire { assertTrue(it.hasSyncPull()); resetResponse() },store).synchronizeIncrementally(4)
        assertEquals(IncrementalSyncResult(1,false,IncrementalSyncStopReason.ResetPending),result)
        assertNull(store.pendingSnapshot()); assertEquals(reset,store.pendingReset());reopen()
        assertEquals(result,SyncEngine(wire { error("No further pull or snapshot request") },store).synchronizeIncrementally(4))
        assertEquals(peer,store.snapshot().blockedUsers.single().target)
        assertTrue(SyncEngine(wire { when {
            it.hasSyncSnapshot() -> {assertEquals(reset.snapshotId,it.syncSnapshot.snapshotId);Envelope.newBuilder().setSnapshotManifest(manifest()).build()}
            it.hasSnapshotAck() -> {assertNull(store.pendingReset());assertNotNull(store.pendingSnapshot());ack()}
            else -> error("Old continuation must not be replayed")
        } },store).synchronizeTurn())
        reopen();assertNull(store.pendingReset());assertNull(store.pendingSnapshot());assertEquals(SyncCursor(2,10,"restored"),store.cursor())
        assertEquals(pending,store.pending().single())
    }
    @Test fun manifestAdoptionAndResetRemovalAreOneTransactionAndMismatchCannotOverwriteJournal() = fixture {
        store.stageReset(store.cursor(),reset)
        fails(IllegalStateException::class.java) {store.stage(manifest().toBuilder().setBaseUserSyncSequence(11).build())}
        fails(IllegalStateException::class.java) {store.cancelReset(reset.copy(generation=3))}
        database {it.execSQL("CREATE TRIGGER reject_reset_removal BEFORE DELETE ON sync_reset BEGIN SELECT RAISE(ABORT,'fixture rollback'); END")}
        fails(SQLiteException::class.java) {store.stage(manifest())}
        assertEquals(reset,store.pendingReset());assertNull(store.pendingSnapshot());reopen()
        assertEquals(reset,store.pendingReset());assertNull(store.pendingSnapshot())
        database {it.execSQL("DROP TRIGGER reject_reset_removal")}
        store.stage(manifest());assertNull(store.pendingReset());assertEquals(manifest(),store.pendingSnapshot())
    }
    @Test fun explicitExpiredResetRejectionPreservesProjectionAndInvalidatesOnlyContinuation() = fixture {
        store.commit(batch(1),store.cursor());store.acknowledged(store.cursor());store.stageReset(store.cursor(),reset);reopen()
        fails(GatewayFailure::class.java) {SyncEngine(wire {assertTrue(it.hasSyncSnapshot());throw GatewayFailure("RESET_REQUIRED",false,0)},store).synchronizeTurn()}
        assertNull(store.pendingReset());assertEquals(SyncCursor(1,1),store.cursor());assertEquals(peer,store.snapshot().blockedUsers.single().target)
        reopen();assertNull(store.pendingReset());assertEquals(SyncCursor(1,1),store.cursor())
    }
    @Test fun pendingResetBlocksIncrementalApplySummaryAndPermissionRecovery() = fixture {
        store.commit(batch(1),store.cursor());store.acknowledged(store.cursor());store.stageReset(store.cursor(),reset)
        fails(IllegalStateException::class.java) {store.commit(batch(2),store.cursor())}
        val scope = store.beginDirectory()
        fails(ClientFailure.ResetRequired::class.java) {store.beginLatestVisible(scope)}
        fails(PolicyRecoverySyncPending::class.java) {store.requestPolicyRecovery(RoomId(UUID.randomUUID().toString()),false)}
        assertEquals(1L,store.cursor().sequence);assertEquals(reset,store.pendingReset())
    }
    @Test fun additiveJournalMigrationPreservesExistingCursorAndProjection() = fixture {
        store.commit(batch(1),store.cursor());store.acknowledged(store.cursor());store.close()
        database {it.execSQL("DROP TABLE sync_reset")};store=SqliteClientStore(context,user,device)
        assertNull(store.pendingReset());assertEquals(SyncCursor(1,1,"old-token"),store.cursor());assertEquals(peer,store.snapshot().blockedUsers.single().target)
        store.stageReset(store.cursor(),reset);reopen();assertEquals(reset,store.pendingReset())
    }
    @Test fun replayedIncrementalPageAcknowledgesItsOwnLowerSequenceWithoutReportingNewRecords() = fixture {
        store.commit(batch(1),store.cursor());store.acknowledged(store.cursor());store.commit(batch(2),store.cursor());store.acknowledged(store.cursor())
        val result=SyncEngine(wire {if(it.hasSyncPull()) Envelope.newBuilder().setSyncBatch(batch(1)).build() else {
            assertEquals(1L,it.syncAck.highestContiguousSequence);assertEquals(2L,store.cursor().sequence);ack()
        }},store).synchronizeIncrementally(4)
        assertEquals(IncrementalSyncResult(1,false,IncrementalSyncStopReason.CaughtUp),result);assertNull(store.cursor().pendingReceipt)
    }
}
