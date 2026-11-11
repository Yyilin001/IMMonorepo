package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.test.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class SyncRecoveryTests {
    private class Store: SyncStore {
        override val syncMutex=Mutex()
        var position=SyncCursor(1,3,"old-token")
        var manifest:SnapshotManifest?=null
        val pages=mutableMapOf<Int,SnapshotPage>()
        val history=mutableMapOf<Long,SyncRecord>()
        var rebuilding=false;var activations=0;var cancellations=0;var discards=0;var resetCancellations=0
        override suspend fun cursor()=position
        override suspend fun commit(batch:SyncBatch,expected:SyncCursor) {
            check(position==expected && manifest==null && !rebuilding)
            for(record in batch.recordsList) if(record.userSyncSequence<=position.sequence) {
                val old=history[record.userSyncSequence] ?: throw SyncReplayUnavailable()
                if(old!=record) throw ClientFailure.Protocol()
            }
            batch.recordsList.forEach {history[it.userSyncSequence]=it}
            position=SyncCursor(batch.generation,maxOf(position.sequence,batch.recordsList.lastOrNull()?.userSyncSequence ?: 0),batch.nextSyncToken,
                batch.syncReceipt.takeIf {batch.recordsCount>0},batch.recordsList.lastOrNull()?.userSyncSequence)
        }
        override suspend fun acknowledged(expected:SyncCursor) {check(position==expected);position=position.copy(pendingReceipt=null,pendingSequence=null)}
        override suspend fun discardSyncCapabilities(expected:SyncCursor) {check(position==expected && manifest==null);discards++;position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
        override suspend fun requestSnapshotRebuild() {rebuilding=true}
        override suspend fun requiresSnapshotRebuild()=rebuilding
        private var reset: SyncReset? = null
    override suspend fun pendingReset() = reset
    override suspend fun stageReset(expected: SyncCursor, reset: SyncReset) {check(position==expected);check(this.reset==null || this.reset==reset);this.reset=reset}
    override suspend fun cancelReset(expected: SyncReset) {check(reset==expected);resetCancellations++;reset=null;position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun pendingSnapshot()=manifest
        override suspend fun stage(manifest:SnapshotManifest) { reset=null;check(this.manifest==null);this.manifest=manifest;pages.clear()}
        override suspend fun cancelSnapshot(expected:SnapshotManifest) {check(manifest==expected);cancellations++;manifest=null;pages.clear();position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
        override suspend fun page(index:Int)=pages[index]
        override suspend fun stage(page:SnapshotPage) {pages[page.pageIndex]=page}
        override suspend fun snapshotImportProgress(manifest:SnapshotManifest)=testSnapshotProgress(manifest)
    override suspend fun importSnapshotPage(manifest:SnapshotManifest,page:SnapshotPage):SnapshotImportProgress {
        val imported=SnapshotImportValidation.advance(manifest,snapshotImportProgress(manifest),page)
        stage(page);return imported.progress
    }
    override suspend fun prepareSnapshotActivation(manifest:SnapshotManifest) {validateSnapshot(testSnapshotItems(manifest))}
    override suspend fun activateAcknowledgedSnapshot(manifest:SnapshotManifest) {activate(manifest,testSnapshotItems(manifest))}
    override suspend fun validateSnapshot(items:PersistentList<SnapshotItem>) {}
        override suspend fun activate(manifest:SnapshotManifest,items:PersistentList<SnapshotItem>) {
            check(this.manifest==manifest);activations++;position=SyncCursor(manifest.generation,manifest.baseUserSyncSequence,manifest.nextSyncToken)
            this.manifest=null;pages.clear();history.clear();rebuilding=false
        }
    }
    private class Wire(val respond:suspend (Envelope)->Envelope):EnvelopeTransport {
        val calls=mutableListOf<Envelope>()
        override suspend fun request(body:Envelope.Builder)=body.build().let {calls+=it;respond(it)}
    }
    private fun record(sequence:Long)=SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("event-$sequence")
        .setProjectionKind("relationship").setPayload(ByteString.copyFromUtf8("{\"sequence\":$sequence}")).build()
    private fun batch(vararg sequences:Long,more:Boolean=false,generation:Long=1)=Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder()
        .setGeneration(generation).setCapabilityProfile("base").setNextSyncToken("next-token").setSyncReceipt("receipt-${sequences.lastOrNull()}")
        .setHasMore(more).addAllRecords(sequences.map(::record))).build()
    private fun ack()=Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private fun manifest(id:String="snapshot",generation:Long=2)=SnapshotManifest.newBuilder().setSnapshotId(id).setGeneration(generation).setBaseUserSyncSequence(10)
        .setSchemaVersion(31).setCapabilityProfile("base").setRootDigest(sha256("IM-SNAPSHOT-V3\u000031\u000010\u0000base".toByteArray()))
        .setNextSyncToken("snapshot-token").setSyncReceipt("snapshot-receipt").setExpiresAtMs(1).build()
    private fun reset(manifest:SnapshotManifest)=Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId(manifest.snapshotId)
        .setGeneration(manifest.generation).setBaseUserSyncSequence(manifest.baseUserSyncSequence)).build()

    @Test fun `terminal page rejection clears shadow and expired capabilities then permits a new baseline`()=runTest {
        val old=manifest().toBuilder().setPageCount(1).setTotalItems(1).setTotalBytes(100).build()
        val store=Store().apply {manifest=old;position=position.copy(pendingReceipt="old-receipt",pendingSequence=3)}
        val rejected=Wire {assertTrue(it.hasSnapshotPagePull());throw GatewayFailure("RESET_REQUIRED",false,0)}
        assertFailsWith<GatewayFailure> {SyncEngine(rejected,store).synchronize()}
        assertNull(store.manifest);assertEquals(SyncCursor(1,3),store.position);assertEquals(1,store.cancellations)
        val next=manifest("replacement",3)
        val wire=Wire {when {it.hasSyncPull()->if(store.activations==0) {assertEquals("",it.syncPull.syncToken);reset(next)} else batch(generation=3)
            it.hasSyncSnapshot()->Envelope.newBuilder().setSnapshotManifest(next).build()
            it.hasSnapshotAck()->ack();else->error("unexpected")}}
        SyncEngine(wire,store).synchronize();assertEquals(1,store.activations);assertEquals(3,store.position.generation)
    }
    @Test fun `uncertain retryable and unrelated snapshot failures retain durable import`()=runTest {
        for(error in listOf(IOException(),GatewayFailure("RESET_REQUIRED",true,1),GatewayFailure("FORBIDDEN",false,0),CancellationException())) {
            val pending=manifest();val store=Store().apply {manifest=pending}
            try {SyncEngine(Wire {throw error},store).synchronize();fail()} catch(actual:Exception) {assertSame(error,actual)}
            assertEquals(pending,store.manifest);assertEquals(0,store.cancellations);assertEquals("old-token",store.position.token)
        }
    }
    @Test fun `expired local timestamp never discards an ACK whose outcome is unknown`()=runTest {
        val pending=manifest();val store=Store().apply {manifest=pending}
        assertFailsWith<IOException> {SyncEngine(Wire {throw IOException()},store).synchronize()}
        val wire=Wire {if(it.hasSnapshotAck()) {assertEquals(pending.syncReceipt,it.snapshotAck.snapshotReceipt);ack()} else batch(generation=2)}
        SyncEngine(wire,store).synchronize();assertEquals(1,store.activations);assertTrue(wire.calls.first().hasSnapshotAck())
    }
    @Test fun `terminal snapshot ACK rejection preserves live watermark and cancels exact import`()=runTest {
        val store=Store().apply {manifest=manifest()}
        assertFailsWith<GatewayFailure> {SyncEngine(Wire {assertTrue(it.hasSnapshotAck());throw GatewayFailure("RESET_REQUIRED",false,0)},store).synchronize()}
        assertEquals(SyncCursor(1,3),store.position);assertEquals(0,store.activations);assertNull(store.manifest)
    }
    @Test fun `manifest rejection clears only old cursor capabilities`()=runTest {
        val store=Store();val pending=manifest()
        val wire=Wire {if(it.hasSyncPull()) reset(pending) else throw GatewayFailure("RESET_REQUIRED",false,0)}
        assertFailsWith<GatewayFailure> {SyncEngine(wire,store).synchronize()}
        assertNull(store.manifest);assertNull(store.pendingReset());assertEquals(SyncCursor(1,3),store.position);assertEquals(1,store.resetCancellations)
    }
    @Test fun `invalid token retries once and replay ACK uses batch end rather than higher live watermark`()=runTest {
        val store=Store().apply {(1L..3L).forEach {history[it]=record(it)}};var pulls=0
        val wire=Wire {if(it.hasSyncAck()) ack() else when(++pulls) {
            1->throw GatewayFailure("SYNC_TOKEN_INVALID",false,0)
            2->{assertEquals("",it.syncPull.syncToken);batch(1,2,more=true)}
            else->batch(3,4)
        }}
        SyncEngine(wire,store).synchronize()
        assertEquals(listOf(2L,4L),wire.calls.filter {it.hasSyncAck()}.map {it.syncAck.highestContiguousSequence})
        assertEquals(SyncCursor(1,4,"next-token"),store.position);assertEquals(1,store.discards)
    }
    @Test fun `second invalid token and retryable first rejection never spin`()=runTest {
        for(retryable in listOf(false,true)) {
            val store=Store();val wire=Wire {throw GatewayFailure("SYNC_TOKEN_INVALID",retryable,1)}
            assertFailsWith<GatewayFailure> {SyncEngine(wire,store).synchronize()}
            assertEquals(if(retryable) 1 else 2,wire.calls.size);assertEquals(if(retryable) 0 else 1,store.discards)
        }
    }
    @Test fun `expired receipt cannot falsely report caught up and restarts from server cursor`()=runTest {
        val store=Store().apply {position=SyncCursor(1)}
        val wire=Wire {if(it.hasSyncAck()) throw GatewayFailure("SYNC_RECEIPT_INVALID",false,0) else batch(1)}
        assertTrue(SyncEngine(wire,store).synchronizeTurn(1));assertEquals(SyncCursor(1,1),store.position)
        val next=Wire {if(it.hasSyncPull()) {assertEquals("",it.syncPull.syncToken);batch(1)} else ack()}
        assertFalse(SyncEngine(next,store).synchronizeTurn(1));assertEquals(1,store.position.sequence)
    }
    @Test fun `missing replay proof requests a snapshot and refuses incremental replacement`()=runTest {
        val store=Store();val wire=Wire {batch(1)}
        assertTrue(SyncEngine(wire,store).synchronizeTurn(1));assertTrue(store.rebuilding)
        assertFalse(wire.calls.any {it.hasSyncAck()});assertEquals(SyncCursor(1,3,"old-token"),store.position)
        val refused=Wire {assertTrue(it.syncPull.requireSnapshot);assertEquals("",it.syncPull.syncToken);batch(4)}
        assertFailsWith<ClientFailure.Protocol> {SyncEngine(refused,store).synchronize()}
        val pending=manifest();val baseline=Wire {when {it.hasSyncPull()->if(store.activations==0) reset(pending) else batch(generation=2)
            it.hasSyncSnapshot()->Envelope.newBuilder().setSnapshotManifest(pending).build();else->ack()}}
        SyncEngine(baseline,store).synchronize();assertFalse(store.rebuilding);assertEquals(1,store.activations)
    }
    @Test fun `conflicting replay is rejected without replacing local evidence`()=runTest {
        val store=Store().apply {history[1]=record(1).toBuilder().setSourceEventId("other").build()}
        val wire=Wire {batch(1)}
        assertFailsWith<ClientFailure.Protocol> {SyncEngine(wire,store).synchronize()}
        assertFalse(store.rebuilding);assertEquals(1,wire.calls.size);assertEquals(3,store.position.sequence)
    }
    @Test fun `replacement engines share the store gate and cancelled waiter cannot release another turn`()=runTest {
        val store=Store();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val first=async {SyncEngine(Wire {entered.complete(Unit);release.await();batch()},store).synchronize()};entered.await()
        val wire=Wire {batch()};val waiting=launch {SyncEngine(wire,store).synchronize()};runCurrent();assertTrue(wire.calls.isEmpty())
        waiting.cancelAndJoin();assertFalse(first.isCompleted);release.complete(Unit);first.await()
        SyncEngine(wire,store).synchronize();assertEquals(1,wire.calls.size)
    }
}
