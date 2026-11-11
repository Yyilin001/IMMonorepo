package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class IncrementalSyncTests {
    private fun ack() = Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private fun batch(sequence: Long?, more: Boolean = false) = Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder()
        .setGeneration(1).setCapabilityProfile("base").setNextSyncToken("next").setSyncReceipt("receipt").setHasMore(more).apply {
            sequence?.let { addRecords(SyncRecord.newBuilder().setUserSyncSequence(it).setSourceEventId("event-$it")
                .setProjectionKind("relationship").setPayload(ByteString.copyFromUtf8("{}"))) }
        }).build()
    private fun reset() = Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId("snapshot")
        .setGeneration(2).setBaseUserSyncSequence(5).setExpiresAtMs(1234)).build()
    @Test fun `page budget commits and acknowledges each page before yielding and resumes exact cursor`() = runTest {
        val store = MemorySync(); val wire = FakeWire { if (it.hasSyncAck()) ack() else batch(store.position.sequence + 1, store.position.sequence < 5) }
        val engine = SyncEngine(wire, store)
        assertEquals(IncrementalSyncResult(4, true, IncrementalSyncStopReason.PageLimit), engine.synchronizeIncrementally(4))
        assertEquals(4, store.position.sequence); assertNull(store.position.pendingReceipt)
        assertEquals(IncrementalSyncResult(2, true, IncrementalSyncStopReason.CaughtUp), engine.synchronizeIncrementally(4))
        assertEquals(6, wire.requests.count { it.hasSyncAck() }); assertEquals("next", wire.requests.last { it.hasSyncPull() }.syncPull.syncToken)
    }
    @Test fun `reset is durable before returning and next bounded call neither pulls nor downloads snapshot`() = runTest {
        val store = MemorySync(); val wire = FakeWire { assertTrue(it.hasSyncPull()); reset() }
        val first = SyncEngine(wire, store).synchronizeIncrementally(4)
        assertEquals(IncrementalSyncResult(1, false, IncrementalSyncStopReason.ResetPending), first)
        assertEquals(SyncReset("snapshot", 2, 5, 1234), store.pendingReset())
        assertEquals(first, SyncEngine(wire, store).synchronizeIncrementally(4)); assertEquals(1, wire.requests.size)
        assertEquals(SyncCursor(1), store.position); assertTrue(store.pages.isEmpty()); assertNull(store.manifest)
    }
    @Test fun `new records before reset are reported without downloading or replacing the old projection`() = runTest {
        val store = MemorySync(); var pulls = 0
        val wire = FakeWire { if (it.hasSyncAck()) ack() else if (++pulls == 1) batch(1, true) else reset() }
        assertEquals(IncrementalSyncResult(2, true, IncrementalSyncStopReason.ResetPending), SyncEngine(wire, store).synchronizeIncrementally(4))
        assertEquals(1, store.position.sequence); assertNull(store.position.pendingReceipt)
    }
    @Test fun `existing imported snapshot and empty pages have distinct incremental outcomes`() = runTest {
        val store = MemorySync(); val wire = FakeWire { batch(null) }
        assertEquals(IncrementalSyncResult(1, false, IncrementalSyncStopReason.CaughtUp), SyncEngine(wire, store).synchronizeIncrementally(1))
        store.manifest = SnapshotManifest.getDefaultInstance()
        assertEquals(IncrementalSyncResult(1, false, IncrementalSyncStopReason.ResetPending), SyncEngine(wire, store).synchronizeIncrementally(1))
        assertEquals(1, wire.requests.size)
    }
    @Test fun `late cancelled pull cannot commit or acknowledge even when transport ignores cancellation`() = runTest {
        val store = MemorySync(); val gate = CompletableDeferred<Unit>()
        val wire = FakeWire { withContext(NonCancellable) { gate.await() }; batch(1) }
        val running = launch { SyncEngine(wire, store).synchronizeIncrementally(4) }; runCurrent()
        running.cancel(); gate.complete(Unit); running.join()
        assertEquals(SyncCursor(1), store.position); assertEquals(1, wire.requests.size)
    }
    @Test fun `queued background cancellation cannot stop the foreground holder of the shared store gate`() = runTest {
        val store = MemorySync(); val gate = CompletableDeferred<Unit>()
        val foregroundWire = FakeWire { if (it.hasSyncAck()) ack() else { gate.await(); batch(1) } }
        val foreground = async { SyncEngine(foregroundWire, store).synchronizeTurn() }; runCurrent()
        val backgroundWire = FakeWire { error("Cancelled waiter must not send") }
        val background = launch { SyncEngine(backgroundWire, store).synchronizeIncrementally(4) }; runCurrent(); background.cancelAndJoin()
        assertTrue(backgroundWire.requests.isEmpty()); assertTrue(foreground.isActive)
        gate.complete(Unit); assertFalse(foreground.await()); assertEquals(1, store.position.sequence)
    }
    @Test fun `foreground resumes stored reset directly and atomically adopts its matching manifest`() = runTest {
        val store = MemorySync(); SyncEngine(FakeWire { reset() }, store).synchronizeIncrementally(1)
        val manifest = SnapshotManifest.newBuilder().setSnapshotId("snapshot").setGeneration(2).setBaseUserSyncSequence(5)
            .setSchemaVersion(31).setCapabilityProfile("base").setRootDigest(sha256("IM-SNAPSHOT-V3\u000031\u00005\u0000base".toByteArray()))
            .setNextSyncToken("restored").setSyncReceipt("snapshot-receipt").build()
        val wire = FakeWire { when {
            it.hasSyncSnapshot() -> { assertEquals("snapshot", it.syncSnapshot.snapshotId); Envelope.newBuilder().setSnapshotManifest(manifest).build() }
            it.hasSnapshotAck() -> ack()
            else -> error("Must not pull with the old token")
        } }
        assertTrue(SyncEngine(wire, store).synchronizeTurn()); assertNull(store.pendingReset()); assertNull(store.manifest)
        assertEquals(SyncCursor(2, 5, "restored"), store.position)
    }
    @Test fun `invalid budget and malformed reset never mutate store`() = runTest {
        val store = MemorySync(); val wire = FakeWire { reset().toBuilder().setResetRequired(ResetRequired.getDefaultInstance()).build() }
        assertFailsWith<IllegalArgumentException> { SyncEngine(wire, store).synchronizeIncrementally(0) }; assertTrue(wire.requests.isEmpty())
        assertFailsWith<ClientFailure.Protocol> { SyncEngine(wire, store).synchronizeIncrementally(1) }; assertNull(store.pendingReset())
    }
}
