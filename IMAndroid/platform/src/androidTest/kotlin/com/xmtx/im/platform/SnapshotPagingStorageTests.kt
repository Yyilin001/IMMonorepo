package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class SnapshotPagingStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString().uppercase())
    private val device=DeviceId(UUID.randomUUID().toString().uppercase())
    private val oldTarget=UserId(UUID.randomUUID().toString().uppercase())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database():SQLiteDatabase {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        return SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE)
    }
    private fun rows(table:String)=database().use {db->db.rawQuery("SELECT COUNT(*) FROM $table",null).use {it.moveToFirst();it.getLong(0)}}
    private suspend fun seed(s:SqliteClientStore) {
        val record=SyncRecord.newBuilder().setUserSyncSequence(1).setSourceEventId("old-event").setProjectionKind("user_block")
            .setPayload(ByteString.copyFromUtf8("""{"target_user_id":"${oldTarget.value}","is_blocked":true,"updated_at_ms":1}"""))
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("old").setSyncReceipt("receipt").addRecords(record).build(),s.cursor())
        s.acknowledged(s.cursor())
    }
    private class Wire(val fixture:SnapshotPagingFixture,var loseAck:Boolean=false):EnvelopeTransport {
        val requests=mutableListOf<Envelope>()
        override suspend fun request(body:Envelope.Builder):Envelope {
            val request=body.build();requests+=request
            return when {
                request.hasSnapshotPagePull()->Envelope.newBuilder().setSnapshotPage(fixture.pages[request.snapshotPagePull.pageIndex]).build()
                request.hasSnapshotAck()->if(loseAck) throw IOException() else Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
                else->error("A snapshot turn must not pull incremental events")
            }
        }
    }
    private suspend fun rejects(block:suspend ()->Unit) {
        try {block();fail("Expected validation failure")} catch(expected:Exception) {assertTrue(expected is ClientFailure.Protocol || expected is IllegalStateException || expected is IllegalArgumentException)}
    }
    @Test fun durablePrefixReopensWithoutReprocessingOrRetainingRawPagesAndActivatesAtomically()=runBlocking {
        val fixture=blockSnapshotFixture(129,8);var s=store()
        val command=MessageCommand.text(actor,RoomId(UUID.randomUUID().toString().uppercase()),"pending",1000)
        try {
            seed(s);s.enqueue(command);s.stage(fixture.manifest);val wire=Wire(fixture)
            assertTrue(SyncEngine(wire,s).synchronizeTurn())
            assertEquals(4,s.snapshotImportProgress(fixture.manifest).nextPage);assertEquals(32L,rows("snapshot_items"));assertEquals(0L,rows("pages"))
            assertEquals(oldTarget,s.snapshot().blockedUsers.single().target)
            s.close();s=store()
            while(s.pendingSnapshot()!=null) {
                val before=wire.requests.size
                assertTrue(SyncEngine(wire,s).synchronizeTurn(maximumSnapshotPages=4))
                assertTrue(wire.requests.drop(before).count {it.hasSnapshotPagePull()}<=4)
            }
            assertEquals((0..128).toList(),wire.requests.filter {it.hasSnapshotPagePull()}.map {it.snapshotPagePull.pageIndex})
            assertEquals(1032,s.snapshot().blockedUsers.size);assertEquals(2L,s.cursor().generation);assertEquals(command,s.pending().single())
            assertEquals(0L,rows("snapshot_import"));assertEquals(0L,rows("snapshot_items"));assertEquals(0L,rows("pages"))
        } finally {s.close()}
    }
    @Test fun acknowledgedPagePrefixSurvivesLostSnapshotAckAndReopenWithoutNetworkPageReplay()=runBlocking {
        val fixture=blockSnapshotFixture(3);var s=store()
        try {
            seed(s);s.stage(fixture.manifest)
            try {SyncEngine(Wire(fixture,true),s).synchronizeTurn();fail()} catch(expected:IOException) {}
            assertEquals(3,s.snapshotImportProgress(fixture.manifest).nextPage);assertEquals(oldTarget,s.snapshot().blockedUsers.single().target)
            s.close();s=store();val wire=Wire(fixture)
            assertTrue(SyncEngine(wire,s).synchronizeTurn())
            assertEquals(1,wire.requests.size);assertTrue(wire.requests.single().hasSnapshotAck())
            assertEquals(fixture.manifest.syncReceipt,wire.requests.single().snapshotAck.snapshotReceipt)
            assertEquals(6,s.snapshot().blockedUsers.size)
        } finally {s.close()}
    }
    @Test fun legacyRawPagesAreImportedAtTheSameBoundedBudgetWithoutRefetchingOrDroppingPrefix()=runBlocking {
        val fixture=blockSnapshotFixture(7);var s=store()
        try {
            seed(s);s.stage(fixture.manifest);fixture.pages.take(5).forEach {s.stage(it)};s.close()
            database().use {it.execSQL("DROP TABLE snapshot_import");it.execSQL("DROP TABLE snapshot_items")}
            s=store();val wire=Wire(fixture)
            SyncEngine(wire,s).synchronizeTurn(maximumSnapshotPages=2)
            assertEquals(2,s.snapshotImportProgress(fixture.manifest).nextPage);assertEquals(3L,rows("pages"));assertTrue(wire.requests.isEmpty())
            while(s.pendingSnapshot()!=null) SyncEngine(wire,s).synchronizeTurn(maximumSnapshotPages=2)
            assertEquals(listOf(5,6),wire.requests.filter {it.hasSnapshotPagePull()}.map {it.snapshotPagePull.pageIndex})
            assertEquals(14,s.snapshot().blockedUsers.size)
        } finally {s.close()}
    }
    @Test fun invalidFinalRootAndCrossPageOrderingLeaveTheLastDurablePrefixUnchanged()=runBlocking {
        val original=blockSnapshotFixture(2,1)
        val fixtures=listOf(original.copy(manifest=original.manifest.toBuilder().setRootDigest("0".repeat(64)).build(),pages=original.pages.map {it.toBuilder().setRootDigest("0".repeat(64)).build()}),
            snapshotFixture(listOf(listOf(original.items[1]),listOf(original.items[0]))))
        val s=store()
        try {
            seed(s)
            for(fixture in fixtures) {
                s.stage(fixture.manifest);s.importSnapshotPage(fixture.manifest,fixture.pages[0]);val before=s.snapshotImportProgress(fixture.manifest)
                rejects {s.importSnapshotPage(fixture.manifest,fixture.pages[1])}
                assertEquals(before,s.snapshotImportProgress(fixture.manifest));assertEquals(1L,rows("snapshot_items"));assertEquals(oldTarget,s.snapshot().blockedUsers.single().target)
                s.cancelSnapshot(fixture.manifest);assertEquals(0L,rows("snapshot_items"));assertEquals(0L,rows("snapshot_import"))
            }
        } finally {s.close()}
    }
    @Test fun decodedShadowAndProgressRollBackTogetherOnSqliteWriteFailure()=runBlocking {
        val fixture=blockSnapshotFixture(2,2);val s=store()
        try {
            s.stage(fixture.manifest)
            database().use {it.execSQL("CREATE TRIGGER fail_shadow BEFORE INSERT ON snapshot_items WHEN NEW.entity_key='${fixture.items[1].key}' BEGIN SELECT RAISE(ABORT,'test shadow write'); END")}
            try {s.importSnapshotPage(fixture.manifest,fixture.pages[0]);fail()} catch(expected:android.database.SQLException) {}
            assertEquals(0L,rows("snapshot_items"));assertEquals(0,s.snapshotImportProgress(fixture.manifest).nextPage)
            database().use {it.execSQL("DROP TRIGGER fail_shadow")}
            assertEquals(1,s.importSnapshotPage(fixture.manifest,fixture.pages[0]).nextPage)
        } finally {s.close()}
    }
    @Test fun semanticProjectionFailurePreventsAckAndPreservesOldProjectionAndStagedRows()=runBlocking {
        val fixture=blockSnapshotFixture(3,2,invalidAt=6);val s=store()
        try {
            seed(s);s.stage(fixture.manifest);val wire=Wire(fixture)
            rejects {SyncEngine(wire,s).synchronizeTurn()}
            assertEquals(3,s.snapshotImportProgress(fixture.manifest).nextPage);assertEquals(6L,rows("snapshot_items"))
            assertEquals(oldTarget,s.snapshot().blockedUsers.single().target);assertEquals(1L,s.cursor().generation)
            assertFalse(wire.requests.any {it.hasSnapshotAck()})
        } finally {s.close()}
    }
    @Test fun wrongManifestDuplicatePageAndPrematureActivationCannotReplaceCurrentImport()=runBlocking {
        val fixture=blockSnapshotFixture(2);val s=store()
        try {
            seed(s);s.stage(fixture.manifest);s.importSnapshotPage(fixture.manifest,fixture.pages[0])
            rejects {s.importSnapshotPage(fixture.manifest,fixture.pages[0])}
            rejects {s.snapshotImportProgress(fixture.manifest.toBuilder().setSnapshotId("other").build())}
            rejects {s.prepareSnapshotActivation(fixture.manifest)}
            rejects {s.activateAcknowledgedSnapshot(fixture.manifest)}
            rejects {s.stage(fixture.pages[0])}
            assertEquals(oldTarget,s.snapshot().blockedUsers.single().target);assertEquals(2L,rows("snapshot_items"))
        } finally {s.close()}
    }
}
