package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundSyncRunnerTests {
    private fun batch(sequence: Long?, more: Boolean = false) = Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder()
        .setGeneration(1).setCapabilityProfile("base").setNextSyncToken("token").setSyncReceipt("receipt").setHasMore(more).apply {
            sequence?.let { addRecords(SyncRecord.newBuilder().setUserSyncSequence(it).setSourceEventId("event-$it").setProjectionKind("relationship").setPayload(ByteString.copyFromUtf8("{}"))) }
        }).build()
    private fun ack() = Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()
    private inner class Harness(val test: TestScope, val budget: BackgroundSyncBudget = BackgroundSyncBudget(),
        val roomSync: (suspend (Int) -> IncrementalSyncResult)? = null, accountScope: CoroutineScope = test) {
        val store = MemorySync()
        var connects = 0; var disconnects = 0; var connected = false
        var connectGate: CompletableDeferred<Unit>? = null; var pullGate: CompletableDeferred<Unit>? = null
        var holdAfterDisconnect = false; var disconnectFailure = false; var wireFailure = false; var reset = false
        var hasMore = false; var empty = false
        val connection = object : BackgroundSyncConnection {
            override suspend fun connect() { connects++; connectGate?.await(); connected = true }
            override fun disconnect() {
                disconnects++; if (disconnectFailure) throw IOException("fixture retirement failure")
                connected = false; if (!holdAfterDisconnect) { connectGate?.complete(Unit); pullGate?.complete(Unit) }
            }
        }
        val wire = FakeWire {
            if (wireFailure) throw IOException("fixture transport failure")
            if (it.hasSyncAck()) ack() else {
                check(it.hasSyncPull())
                pullGate?.let { gate -> withContext(NonCancellable) { gate.await() } }
                if (reset) Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId("snapshot").setGeneration(2)).build()
                else batch(if (empty) null else store.position.sequence + 1, hasMore)
            }
        }
        fun now() = test.testScheduler.currentTime * 1_000_000
        val runner = BackgroundSyncRunner(connection,SyncEngine(wire,store),accountScope,roomSync,budget,::now)
    }
    @Test fun `concurrent callers share one connection and cancellation of initiator leaves other waiter running`() = runTest {
        val h=Harness(this);h.pullGate=CompletableDeferred()
        val first=launch { h.runner.run() };runCurrent()
        val second=async { h.runner.run() };runCurrent();first.cancelAndJoin()
        assertEquals(1,h.connects);assertEquals(0,h.disconnects);assertTrue(second.isActive)
        h.pullGate!!.complete(Unit);assertEquals(IncrementalSyncResult(1,true,IncrementalSyncStopReason.CaughtUp),second.await())
        assertEquals(1,h.disconnects);assertFalse(h.connected)
    }
    @Test fun `earlier joining deadline exits only that waiter while initiator waits for shared result`() = runTest {
        val h=Harness(this);h.pullGate=CompletableDeferred()
        val first=async { h.runner.run() };runCurrent()
        val joining=async {runCatching {h.runner.run(h.now()+100_000_000)}};runCurrent();advanceTimeBy(101);runCurrent()
        assertIs<BackgroundSyncDeadlineReached>(joining.await().exceptionOrNull());assertEquals(0,h.disconnects);assertTrue(first.isActive)
        h.pullGate!!.complete(Unit);first.await();assertEquals(1,h.connects);assertEquals(1,h.disconnects)
    }
    @Test fun `initiating deadline closes blocked transport and waits for actual drain before reporting expiry`() = runTest {
        val h=Harness(this);h.pullGate=CompletableDeferred();h.holdAfterDisconnect=true
        val first=async {runCatching {h.runner.run(h.now()+100_000_000)}};runCurrent()
        advanceTimeBy(101);runCurrent();assertEquals(1,h.disconnects);assertFalse(first.isCompleted)
        h.pullGate!!.complete(Unit);assertIs<BackgroundSyncDeadlineReached>(first.await().exceptionOrNull())
        assertEquals(SyncCursor(1),h.store.position);assertFalse(h.wire.requests.any {it.hasSyncAck()})
    }
    @Test fun `default work deadline includes connection establishment and never starts sync after cancellation`() = runTest {
        val h=Harness(this,BackgroundSyncBudget(workDurationMillis=100));h.connectGate=CompletableDeferred()
        val work=async {runCatching {h.runner.run()}};runCurrent();advanceTimeBy(101);runCurrent()
        assertIs<BackgroundSyncDeadlineReached>(work.await().exceptionOrNull());assertEquals(1,h.disconnects);assertTrue(h.wire.requests.isEmpty())
    }
    @Test fun `stop callers share drain reject new work and allow a later fresh operation`() = runTest {
        val h=Harness(this);h.pullGate=CompletableDeferred();h.holdAfterDisconnect=true
        val work=async {runCatching {h.runner.run()}};runCurrent()
        val a=launch {h.runner.stop()};val b=launch {h.runner.stop()};runCurrent()
        assertFalse(a.isCompleted);assertFalse(b.isCompleted)
        assertFailsWith<CancellationException> {h.runner.run()}
        a.cancel();runCurrent();assertFalse(a.isCompleted) // stop itself remains non-cancellable until drain.
        val before=h.disconnects;assertEquals(2,before) // Owner stop plus the operation's idempotent final close.
        h.pullGate!!.complete(Unit);a.join();b.join();assertEquals(before,h.disconnects)
        assertIs<CancellationException>(work.await().exceptionOrNull());assertEquals(SyncCursor(1),h.store.position)
        h.pullGate=null;h.holdAfterDisconnect=false
        assertTrue(h.runner.run().didCommitNewRecords);assertEquals(2,h.connects)
    }
    @Test fun `page budget reserves room recovery even when personal stream remains hot`() = runTest {
        var allowed=0
        val h=Harness(this,BackgroundSyncBudget(maximumPages=5),roomSync={remaining->allowed=remaining;IncrementalSyncResult(remaining,true,IncrementalSyncStopReason.CaughtUp)})
        h.hasMore=true
        assertEquals(IncrementalSyncResult(5,true,IncrementalSyncStopReason.PageLimit),h.runner.run())
        assertEquals(3,allowed);assertEquals(2,h.wire.requests.count {it.hasSyncPull()})
    }
    @Test fun `reset bypasses room work while empty personal feed gives remaining budget to rooms`() = runTest {
        var calls=0
        val h=Harness(this,roomSync={remaining->calls++;assertEquals(3,remaining);IncrementalSyncResult(1,false,IncrementalSyncStopReason.CaughtUp)})
        h.reset=true;assertEquals(IncrementalSyncStopReason.ResetPending,h.runner.run().stopReason);assertEquals(0,calls)
        h.store.cancelReset(requireNotNull(h.store.pendingReset()));h.reset=false;h.empty=true
        assertEquals(IncrementalSyncResult(2,false,IncrementalSyncStopReason.CaughtUp),h.runner.run());assertEquals(1,calls)
    }
    @Test fun `room result and page limit are merged and invalid room budget consumption is rejected`() = runTest {
        val h=Harness(this,roomSync={IncrementalSyncResult(1,false,IncrementalSyncStopReason.ResetPending)})
        assertEquals(IncrementalSyncResult(2,true,IncrementalSyncStopReason.PageLimit),h.runner.run())
        val bad=Harness(this,roomSync={IncrementalSyncResult(it+1,false,IncrementalSyncStopReason.CaughtUp)})
        assertFailsWith<IllegalArgumentException> {bad.runner.run()};assertEquals(1,bad.disconnects)
    }
    @Test fun `background expiry queued behind foreground store gate leaves foreground transport and commit intact`() = runTest {
        val h=Harness(this,BackgroundSyncBudget(workDurationMillis=100));val gate=CompletableDeferred<Unit>()
        val foregroundWire=FakeWire {if(it.hasSyncAck()) ack() else {gate.await();batch(1)}}
        val foreground=async {SyncEngine(foregroundWire,h.store).synchronizeTurn()};runCurrent()
        val background=async {runCatching {h.runner.run()}};runCurrent();advanceTimeBy(101);runCurrent()
        assertIs<BackgroundSyncDeadlineReached>(background.await().exceptionOrNull());assertTrue(h.wire.requests.isEmpty());assertTrue(foreground.isActive)
        gate.complete(Unit);assertFalse(foreground.await());assertEquals(1,h.store.position.sequence);assertEquals(1,h.disconnects)
    }
    @Test fun `account cancellation closes actual transport and drains while caller scope remains separate`() = runTest {
        val account=Job();val h=Harness(this,accountScope=CoroutineScope(coroutineContext+account));h.pullGate=CompletableDeferred()
        val caller=async {runCatching {h.runner.run()}};runCurrent();account.cancel();runCurrent()
        assertIs<CancellationException>(caller.await().exceptionOrNull());account.join();assertEquals(1,h.disconnects)
        assertEquals(SyncCursor(1),h.store.position);assertFailsWith<CancellationException> {h.runner.run()}
        h.runner.stop()
    }
    @Test fun `transport failure disconnects once and does not poison the account or the next operation`() = runTest {
        val h=Harness(this);h.wireFailure=true
        assertFailsWith<IOException> {h.runner.run()};assertEquals(1,h.disconnects);assertTrue(currentCoroutineContext().isActive)
        h.wireFailure=false;assertTrue(h.runner.run().didCommitNewRecords);assertEquals(2,h.connects)
    }
    @Test fun `failed retirement blocks connection reuse until an explicit successful stop`() = runTest {
        val h=Harness(this);h.disconnectFailure=true
        assertFailsWith<IOException> {h.runner.run()};assertFailsWith<IllegalStateException> {h.runner.run()};assertEquals(1,h.connects)
        h.disconnectFailure=false;h.runner.stop();assertTrue(h.runner.run().didCommitNewRecords)
    }
    @Test fun `expired or cancelled callers cannot initiate work and budgets reject invalid bounds`() = runTest {
        val h=Harness(this)
        assertFailsWith<BackgroundSyncDeadlineReached> {h.runner.run(h.now())};assertEquals(0,h.connects)
        launch {currentCoroutineContext().cancel();assertFailsWith<CancellationException> {h.runner.run()}}.join()
        assertEquals(0,h.connects)
        for (pages in listOf(0,10_001)) assertFailsWith<IllegalArgumentException> {BackgroundSyncBudget(maximumPages=pages)}
        assertFailsWith<IllegalArgumentException> {BackgroundSyncBudget(workDurationMillis=0)}
        assertFailsWith<IllegalArgumentException> {BackgroundSyncBudget(workDurationMillis=Long.MAX_VALUE)}
    }
    @Test fun `cancelling the only waiter leaves bounded owner work alive until its own deadline`() = runTest {
        val h=Harness(this,BackgroundSyncBudget(workDurationMillis=100));h.pullGate=CompletableDeferred()
        val waiter=launch {h.runner.run()};runCurrent();waiter.cancelAndJoin()
        assertEquals(0,h.disconnects);advanceTimeBy(101);runCurrent()
        assertEquals(1,h.disconnects);assertEquals(SyncCursor(1),h.store.position)
        h.pullGate=null;assertTrue(h.runner.run().didCommitNewRecords)
    }
    @Test fun `room work uses the original deadline and a one page budget never enters room recovery`() = runTest {
        var completed=false
        val h=Harness(this,BackgroundSyncBudget(workDurationMillis=100),roomSync={delay(1000);completed=true;IncrementalSyncResult(1,false,IncrementalSyncStopReason.CaughtUp)})
        val result=async {runCatching {h.runner.run()}};runCurrent();advanceTimeBy(101);runCurrent()
        assertIs<BackgroundSyncDeadlineReached>(result.await().exceptionOrNull());assertFalse(completed);assertEquals(1,h.disconnects)
        val single=Harness(this,BackgroundSyncBudget(maximumPages=1),roomSync={error("No room budget remains")})
        assertEquals(IncrementalSyncResult(1,true,IncrementalSyncStopReason.CaughtUp),single.runner.run())
    }

}
