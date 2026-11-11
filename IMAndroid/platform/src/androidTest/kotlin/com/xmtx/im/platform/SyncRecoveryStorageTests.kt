package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class SyncRecoveryStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString().uppercase())
    private val device=DeviceId(UUID.randomUUID().toString().uppercase())
    private val target=UserId(UUID.randomUUID().toString().uppercase())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database():SQLiteDatabase {
        val digest=sha("${actor.value}/${device.value}".toByteArray())
        return SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE)
    }
    private fun sha(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it)}
    private fun record(sequence:Long,blocked:Boolean)=SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("event-$sequence").setProjectionKind("user_block")
        .setPayload(ByteString.copyFromUtf8("""{"target_user_id":"${target.value}","is_blocked":$blocked,"updated_at_ms":$sequence}""")).build()
    private fun batch(vararg records:SyncRecord)=SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("token").setSyncReceipt("receipt").addAllRecords(records.toList()).build()
    private fun manifest()=SnapshotManifest.newBuilder().setSnapshotId(UUID.randomUUID().toString()).setGeneration(2).setBaseUserSyncSequence(10).setSchemaVersion(31)
        .setCapabilityProfile("base").setRootDigest(sha("IM-SNAPSHOT-V3\u000031\u000010\u0000base".toByteArray())).setNextSyncToken("snapshot-token").setSyncReceipt("snapshot-receipt").setExpiresAtMs(1).build()
    private fun ack()=Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private suspend fun expectFailure(type:Class<out Throwable>,body:suspend ()->Unit) {
        try {body();fail("Expected ${type.simpleName}")} catch(error:Throwable) {if(!type.isInstance(error)) throw error}
    }
    @Test fun replayPreservesNewerProjectionAndPersistsTheLowerReceiptAcrossReopen()=runBlocking {
        var s=store()
        try {
            s.commit(batch(record(1,false),record(2,true)),s.cursor());s.acknowledged(s.cursor())
            s.commit(batch(record(1,false)),s.cursor())
            assertEquals(2L,s.cursor().sequence);assertEquals(1L,s.cursor().pendingSequence);assertEquals(target,s.snapshot().blockedUsers.single().target)
            s.close();s=store()
            val calls=mutableListOf<Envelope>()
            val wire=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                val value=body.build();calls+=value
                if(value.hasSyncAck()) return ack()
                throw IOException()
            }}
            expectFailure(IOException::class.java) {SyncEngine(wire,s).synchronize()}
            assertEquals(1L,calls.first().syncAck.highestContiguousSequence);assertEquals(2L,s.cursor().sequence);assertNull(s.cursor().pendingReceipt)
            assertEquals(target,s.snapshot().blockedUsers.single().target)
        } finally {s.close()}
    }
    @Test fun conflictingReplayRollsBackTheWholeBatchWithoutClearingEvidence()=runBlocking {
        val s=store()
        try {
            s.commit(batch(record(1,false),record(2,true)),s.cursor());val before=s.cursor()
            expectFailure(ClientFailure.Protocol::class.java) {s.commit(batch(record(1,false),record(2,false),record(3,false)),before)}
            assertEquals(before,s.cursor());assertEquals(target,s.snapshot().blockedUsers.single().target)
            database().use {db->db.rawQuery("SELECT COUNT(*) FROM sync_history",null).use {it.moveToFirst();assertEquals(2,it.getInt(0))}}
        } finally {s.close()}
    }
    @Test fun terminalSnapshotRejectionClearsOnlyMatchingShadowAndCapabilities()=runBlocking {
        var s=store();val pending=manifest().toBuilder().setPageCount(1).setTotalItems(1).setTotalBytes(100).build()
        val command=MessageCommand.text(actor,RoomId(UUID.randomUUID().toString().uppercase()),"pending",1000)
        try {
            s.commit(batch(record(1,true)),s.cursor());s.enqueue(command);s.stage(pending)
            val page=SnapshotPage.newBuilder().setSnapshotId(pending.snapshotId).setGeneration(pending.generation).setRootDigest(pending.rootDigest).setPageIndex(0).build()
            s.stage(page);s.close();s=store()
            expectFailure(IllegalStateException::class.java) {s.cancelSnapshot(pending.toBuilder().setSnapshotId("other").build())}
            assertEquals(page,s.page(0));assertEquals(pending,s.pendingSnapshot())
            s.cancelSnapshot(pending)
            assertNull(s.pendingSnapshot());assertNull(s.page(0));assertEquals(SyncCursor(1,1),s.cursor())
            assertEquals(command,s.pending().single());assertEquals(target,s.snapshot().blockedUsers.single().target)
            s.close();s=store();assertNull(s.pendingSnapshot());assertEquals(SyncCursor(1,1),s.cursor())
        } finally {s.close()}
    }
    @Test fun missingReplayEvidenceRequiresDurableBaselineAndRejectsAnIncrementalSubstitute()=runBlocking {
        var s=store()
        try {
            s.commit(batch(record(1,true)),s.cursor());s.acknowledged(s.cursor())
            database().use {it.execSQL("DELETE FROM sync_history")}
            val response=Envelope.newBuilder().setSyncBatch(batch(record(1,true))).build()
            val wire=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder)=response}
            assertTrue(SyncEngine(wire,s).synchronizeTurn(1));assertTrue(s.requiresSnapshotRebuild());assertEquals(target,s.snapshot().blockedUsers.single().target)
            s.close();s=store();assertTrue(s.requiresSnapshotRebuild())
            expectFailure(ClientFailure.Protocol::class.java) {SyncEngine(wire,s).synchronize()}
            val pending=manifest();s.stage(pending)
            val calls=mutableListOf<Envelope>()
            val recovered=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                val value=body.build();calls+=value
                if(value.hasSnapshotAck()) return ack()
                throw IOException()
            }}
            expectFailure(IOException::class.java) {SyncEngine(recovered,s).synchronize()}
            assertTrue(calls.first().hasSnapshotAck());assertFalse(s.requiresSnapshotRebuild());assertEquals(SyncCursor(2,10,"snapshot-token"),s.cursor())
            assertTrue(s.snapshot().blockedUsers.isEmpty())
        } finally {s.close()}
    }
    @Test fun oldCursorSchemaMigratesExactPendingReceiptAndUsesFullSnapshotWhenHistoryIsMissing()=runBlocking {
        store().close()
        database().use {db->
            db.execSQL("DROP TABLE cursor")
            db.execSQL("CREATE TABLE cursor(id INTEGER PRIMARY KEY,generation INTEGER NOT NULL,sequence INTEGER NOT NULL,token TEXT NOT NULL,receipt TEXT)")
            db.execSQL("INSERT INTO cursor VALUES(1,1,7,'old-token','old-receipt')")
            db.execSQL("DROP TABLE sync_history");db.execSQL("DROP TABLE sync_rebuild")
        }
        val s=store()
        try {
            assertEquals(SyncCursor(1,7,"old-token","old-receipt",7),s.cursor())
            s.discardSyncCapabilities(s.cursor());assertEquals(SyncCursor(1,7),s.cursor())
            expectFailure(SyncReplayUnavailable::class.java) {s.commit(batch(record(1,true)),s.cursor())}
            assertEquals(SyncCursor(1,7),s.cursor())
        } finally {s.close()}
    }
    @Test fun ACKLossResumesDurableSnapshotBeforeAnyOldTokenPullAndKeepsOutbox()=runBlocking {
        var s=store();val pending=manifest()
        val command=MessageCommand.text(actor,RoomId(UUID.randomUUID().toString().uppercase()),"pending",1000)
        try {
            s.commit(batch(record(1,true)),s.cursor());s.enqueue(command);s.stage(pending)
            expectFailure(IOException::class.java) {SyncEngine(object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope=throw IOException()},s).synchronize()}
            assertEquals(pending,s.pendingSnapshot());assertEquals(target,s.snapshot().blockedUsers.single().target)
            s.close();s=store();var first=true
            expectFailure(IOException::class.java) {SyncEngine(object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {
                if(first) {first=false;assertTrue(body.hasSnapshotAck());assertEquals(pending.syncReceipt,body.snapshotAck.snapshotReceipt);return ack()}
                throw IOException()
            }},s).synchronize()}
            assertNull(s.pendingSnapshot());assertEquals(2L,s.cursor().generation);assertEquals(command,s.pending().single())
        } finally {s.close()}
    }
}
