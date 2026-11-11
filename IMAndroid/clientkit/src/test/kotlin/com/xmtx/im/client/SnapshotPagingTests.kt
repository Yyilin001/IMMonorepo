package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class SnapshotPagingTests {
    private fun ack()=Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private fun batch()=Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder().setGeneration(2).setCapabilityProfile("base").setNextSyncToken("next").setSyncReceipt("receipt")).build()
    private fun wire(fixture:SnapshotPagingFixture)=FakeWire {request->when {
        request.hasSnapshotPagePull()->Envelope.newBuilder().setSnapshotPage(fixture.pages[request.snapshotPagePull.pageIndex]).build()
        request.hasSnapshotAck()->ack()
        else->batch()
    }}
    @Test fun `snapshot turn has independent page budget and completion waits for post activation pull`()=runTest {
        val fixture=blockSnapshotFixture();val store=MemorySync().apply {manifest=fixture.manifest};val wire=wire(fixture)
        repeat(2) {
            assertTrue(SyncEngine(wire,store).synchronizeTurn(maximumBatches=100,maximumSnapshotPages=4))
            assertEquals(1,store.cursor().generation);assertEquals((it+1)*4,store.pages.size)
            assertFalse(wire.requests.any {it.hasSyncPull() || it.hasSnapshotAck()})
        }
        assertNull(SyncEngine(wire,store).synchronizeForCompletion(maximumSnapshotPages=4))
        assertEquals(2,store.cursor().generation);assertNull(store.manifest)
        assertEquals(9,wire.requests.count {it.hasSnapshotPagePull()});assertEquals(1,wire.requests.count {it.hasSnapshotAck()})
        assertNotNull(SyncEngine(wire,store).synchronizeForCompletion())
        assertTrue(wire.requests.any {it.hasSyncPull()})
    }
    @Test fun `newly discovered snapshot consumes one budget rather than draining before return`()=runTest {
        val fixture=blockSnapshotFixture(7);val store=MemorySync()
        val wire=FakeWire {request->when {
            request.hasSyncPull()->Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId(fixture.manifest.snapshotId).setGeneration(2).setBaseUserSyncSequence(fixture.manifest.baseUserSyncSequence)).build()
            request.hasSyncSnapshot()->Envelope.newBuilder().setSnapshotManifest(fixture.manifest).build()
            request.hasSnapshotPagePull()->Envelope.newBuilder().setSnapshotPage(fixture.pages[request.snapshotPagePull.pageIndex]).build()
            else->error("Premature ACK")
        }}
        assertTrue(SyncEngine(wire,store).synchronizeTurn(maximumSnapshotPages=2))
        assertEquals(2,store.pages.size);assertEquals(1,wire.requests.count {it.hasSyncPull()})
    }
    @Test fun `interruption retains completed prefix and replacement engine requests only remaining pages`()=runTest {
        val fixture=blockSnapshotFixture(3);val store=MemorySync().apply {manifest=fixture.manifest}
        val failing=FakeWire {request->if(request.snapshotPagePull.pageIndex==1) throw IOException() else Envelope.newBuilder().setSnapshotPage(fixture.pages[0]).build()}
        assertFailsWith<IOException> {SyncEngine(failing,store).synchronizeTurn()}
        assertEquals(setOf(0),store.pages.keys)
        val wire=wire(fixture);SyncEngine(wire,store).synchronize()
        assertEquals(listOf(1,2),wire.requests.filter {it.hasSnapshotPagePull()}.map {it.snapshotPagePull.pageIndex})
        assertNull(store.manifest)
    }
    @Test fun `cross page key regression fails even when per page and root digests are correct`()=runTest {
        val items=blockSnapshotFixture(2,1).items
        val fixture=snapshotFixture(listOf(listOf(items[1]),listOf(items[0])))
        val store=MemorySync().apply {manifest=fixture.manifest};val wire=wire(fixture)
        assertTrue(SyncEngine(wire,store).synchronizeTurn(maximumSnapshotPages=1))
        assertFailsWith<ClientFailure.Protocol> {SyncEngine(wire,store).synchronizeTurn(maximumSnapshotPages=1)}
        assertEquals(1,store.pages.size);assertEquals(1,store.cursor().generation)
        assertFalse(wire.requests.any {it.hasSnapshotAck()})
    }
    @Test fun `wrong root never commits final page or acknowledges partial snapshot`()=runTest {
        val valid=blockSnapshotFixture(2,1)
        val fixture=valid.copy(manifest=valid.manifest.toBuilder().setRootDigest("0".repeat(64)).build(),pages=valid.pages.map {it.toBuilder().setRootDigest("0".repeat(64)).build()})
        val store=MemorySync().apply {manifest=fixture.manifest};val wire=wire(fixture)
        assertFailsWith<ClientFailure.Protocol> {SyncEngine(wire,store).synchronizeTurn()}
        assertEquals(setOf(0),store.pages.keys);assertFalse(wire.requests.any {it.hasSnapshotAck()})
    }
    @Test fun `unbounded convenience sync still observes bounded turns and validates page budget`()=runTest {
        val fixture=blockSnapshotFixture(13);val store=MemorySync().apply {manifest=fixture.manifest};val wire=wire(fixture)
        assertFailsWith<IllegalArgumentException> {SyncEngine(wire,store).synchronizeTurn(maximumSnapshotPages=0)}
        assertTrue(wire.requests.isEmpty())
        SyncEngine(wire,store).synchronize()
        assertEquals((0..12).toList(),wire.requests.filter {it.hasSnapshotPagePull()}.map {it.snapshotPagePull.pageIndex})
        assertNull(store.manifest);assertEquals(2,store.cursor().generation)
    }
}
