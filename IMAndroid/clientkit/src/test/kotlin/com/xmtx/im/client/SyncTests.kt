package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

internal class MemorySync : SyncStore {
    var position = SyncCursor(1)
    var failCommit = false
    var manifest: SnapshotManifest? = null
    val pages = mutableMapOf<Int, SnapshotPage>()
    override val syncMutex=kotlinx.coroutines.sync.Mutex()
    private var rebuild=false
    override suspend fun requiresSnapshotRebuild()=rebuild
    override suspend fun requestSnapshotRebuild() {rebuild=true}
    override suspend fun discardSyncCapabilities(expected: SyncCursor) {check(position==expected);position=expected.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun cancelSnapshot(expected: SnapshotManifest) {check(manifest==expected);manifest=null;pages.clear();position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun cursor() = position
    override suspend fun commit(batch: SyncBatch, expected: SyncCursor) {
        if (failCommit) throw IOException()
        check(position == expected)
        position = SyncCursor(batch.generation, batch.recordsList.lastOrNull()?.userSyncSequence ?: expected.sequence, batch.nextSyncToken, batch.syncReceipt.takeIf {batch.recordsCount>0})
    }
    override suspend fun acknowledged(expected: SyncCursor) { check(position == expected); position = position.copy(pendingReceipt = null,pendingSequence=null) }
    private var reset: SyncReset? = null
    override suspend fun pendingReset() = reset
    override suspend fun stageReset(expected: SyncCursor, reset: SyncReset) {check(position==expected);check(this.reset==null || this.reset==reset);this.reset=reset}
    override suspend fun cancelReset(expected: SyncReset) {check(reset==expected);reset=null;position=position.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun pendingSnapshot() = manifest
    override suspend fun stage(manifest: SnapshotManifest) { reset=null; this.manifest = manifest }
    override suspend fun page(index: Int) = pages[index]
    override suspend fun stage(page: SnapshotPage) { pages[page.pageIndex] = page }
    override suspend fun snapshotImportProgress(manifest:SnapshotManifest)=testSnapshotProgress(manifest)
    override suspend fun importSnapshotPage(manifest:SnapshotManifest,page:SnapshotPage):SnapshotImportProgress {
        val imported=SnapshotImportValidation.advance(manifest,snapshotImportProgress(manifest),page)
        stage(page);return imported.progress
    }
    override suspend fun prepareSnapshotActivation(manifest:SnapshotManifest) {validateSnapshot(testSnapshotItems(manifest))}
    override suspend fun activateAcknowledgedSnapshot(manifest:SnapshotManifest) {activate(manifest,testSnapshotItems(manifest))}
    override suspend fun validateSnapshot(items: PersistentList<SnapshotItem>) {}
    override suspend fun activate(manifest: SnapshotManifest, items: PersistentList<SnapshotItem>) {
        position = SyncCursor(manifest.generation, manifest.baseUserSyncSequence, manifest.nextSyncToken); this.manifest = null
    }
}
internal class FakeWire(val handler: suspend (Envelope) -> Envelope) : EnvelopeTransport {
    val requests = mutableListOf<Envelope>()
    override suspend fun request(body: Envelope.Builder): Envelope = body.build().let { requests += it; handler(it) }
}
class SyncTests {
    private fun batch(sequence: Long = 1) = Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base")
        .setNextSyncToken("opaque-next").setSyncReceipt("exact-receipt")
        .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("event").setProjectionKind("relationship").setPayload(ByteString.copyFromUtf8("{}")))).build()
    private fun ack() = Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    @Test fun `bounded turn yields after committed acknowledgements and resumes exact cursor`() = runTest {
        val store=MemorySync()
        val wire=FakeWire { request ->
            if(request.hasSyncAck()) { assertEquals(store.position.sequence,request.syncAck.highestContiguousSequence);ack() }
            else batch(store.position.sequence+1).toBuilder().apply { syncBatch=syncBatch.toBuilder().setHasMore(store.position.sequence < 4).build() }.build()
        }
        val engine=SyncEngine(wire,store)
        assertTrue(engine.synchronizeTurn(2));assertEquals(2,store.position.sequence);assertNull(store.position.pendingReceipt)
        assertTrue(engine.synchronizeTurn(2));assertEquals(4,store.position.sequence)
        assertFalse(engine.synchronizeTurn(2));assertEquals(5,store.position.sequence)
        assertEquals(5,wire.requests.count {it.hasSyncAck()})
    }
    @Test fun `failed transaction never sends ACK`() = runTest {
        val store = MemorySync().apply { failCommit = true }; val wire = FakeWire { batch() }
        assertFailsWith<IOException> { SyncEngine(wire, store).synchronize() }
        assertEquals(SyncCursor(1), store.position); assertFalse(wire.requests.any { it.hasSyncAck() })
    }
    @Test fun `ACK sees committed cursor token and exact receipt`() = runTest {
        val store = MemorySync()
        val wire = FakeWire { request ->
            if (request.hasSyncPull()) batch() else {
                assertEquals(SyncCursor(1, 1, "opaque-next", "exact-receipt"), store.position)
                assertEquals("exact-receipt", request.syncAck.syncReceipt); ack()
            }
        }
        SyncEngine(wire, store).synchronize()
        assertEquals(SyncCursor(1, 1, "opaque-next"), store.position)
    }
    @Test fun `restart replays persisted ACK before pulling again`() = runTest {
        val store = MemorySync().apply { position = SyncCursor(1, 12, "opaque", "pending") }
        val wire = FakeWire { request -> if (request.hasSyncAck()) ack() else throw IOException() }
        assertFailsWith<IOException> { SyncEngine(wire, store).synchronize() }
        assertEquals("pending", wire.requests.first().syncAck.syncReceipt)
        assertEquals("opaque", wire.requests.last().syncPull.syncToken)
    }
    @Test fun `sequence gap cannot advance local watermark`() = runTest {
        val store = MemorySync(); val wire = FakeWire { batch(2) }
        assertFailsWith<ClientFailure.Protocol> { SyncEngine(wire, store).synchronize() }
        assertEquals(0, store.position.sequence); assertEquals(1, wire.requests.size)
    }
    @Test fun `invalid snapshot digest never activates or acknowledges`() = runTest {
        val store = MemorySync().apply { manifest = SnapshotManifest.newBuilder().setSnapshotId("snapshot").setGeneration(2).setBaseUserSyncSequence(10)
            .setSchemaVersion(31).setCapabilityProfile("base").setRootDigest("0".repeat(64)).setNextSyncToken("new-token").setSyncReceipt("snapshot-receipt").build() }
        val wire = FakeWire { error("No network request expected") }
        assertFailsWith<ClientFailure.Protocol> { SyncEngine(wire, store).synchronize() }
        assertNotNull(store.manifest); assertEquals(1, store.position.generation)
    }
    @Test fun `empty snapshot survives ACK failure and commits only on replay success`() = runTest {
        val store = MemorySync().apply { manifest = SnapshotManifest.newBuilder().setSnapshotId("snapshot").setGeneration(2).setBaseUserSyncSequence(10)
            .setSchemaVersion(31).setCapabilityProfile("base").setRootDigest(sha256("IM-SNAPSHOT-V3\u000031\u000010\u0000base".toByteArray()))
            .setNextSyncToken("new-token").setSyncReceipt("snapshot-receipt").build() }
        assertFailsWith<IOException> { SyncEngine(FakeWire { throw IOException() }, store).synchronize() }
        assertNotNull(store.manifest); assertEquals(1, store.position.generation)
        val wire = FakeWire { request -> if (request.hasSnapshotAck()) ack() else throw IOException() }
        assertFailsWith<IOException> { SyncEngine(wire, store).synchronize() }
        assertNull(store.manifest); assertEquals(SyncCursor(2, 10, "new-token"), store.position)
    }
}
