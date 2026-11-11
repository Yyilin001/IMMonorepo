package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RealtimeCoverageTests {
    private val room = "00000000-0000-0000-0000-00000000000A"
    private fun wire(scope: RealtimeCoverage.Scope = RealtimeCoverage.Scope.ROOM) = RealtimeCoverage.newBuilder()
        .setScope(scope).setScopeId(room).setRevision(1).setScopeGeneration(1).setHighWatermark(10)
        .setState(RealtimeCoverage.State.READY).setConnectionEpoch(room)
    private fun decode(value: RealtimeCoverage.Builder, epoch: Long = 1) = RealtimeCoverageState.decode(value.build(), epoch)
    @Test fun `all scopes enforce wire reason identity and numeric bounds`() {
        for (scope in listOf(RealtimeCoverage.Scope.ACCOUNT, RealtimeCoverage.Scope.ROOM, RealtimeCoverage.Scope.DIRECTORY, RealtimeCoverage.Scope.PRESENCE, RealtimeCoverage.Scope.TYPING)) {
            val value = wire(scope)
            assertTrue(decode(value).subscriptionInstalled)
            assertEquals(10, decode(value).baselineHead)
            assertFalse(decode(value).isCaughtUp(9)); assertTrue(decode(value).isCaughtUp(10))
            value.setReason(RealtimeCoverage.Reason.INSTALLING)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setState(RealtimeCoverage.State.RECOVERING)
            assertNull(decode(value).baselineHead); assertFalse(decode(value).isCaughtUp(100))
            value.setReason(RealtimeCoverage.Reason.CANCELLED)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setState(RealtimeCoverage.State.ENDED); assertFalse(decode(value).subscriptionInstalled)
            value.setReason(RealtimeCoverage.Reason.REASON_UNSPECIFIED)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setState(RealtimeCoverage.State.READY).setScopeId("1-1-1-1-1")
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setScopeId(room).setHighWatermark(-1)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setHighWatermark(0).setRevision(0)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setRevision(1).setScopeGeneration(0)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
            value.setScopeGeneration(1).setReasonValue(99)
            assertFailsWith<ClientFailure.Protocol> { decode(value) }
        }
        assertFailsWith<ClientFailure.Protocol> { decode(wire().setScopeValue(99)) }
        assertFailsWith<ClientFailure.Protocol> { decode(wire(RealtimeCoverage.Scope.DIRECTORY).setConnectionEpoch("invalid")) }
    }
    @Test fun `five bounded fences reject stale and ended generations and preserve immutable snapshots`() {
        val tracker = RealtimeCoverageTracker(7)
        for (scope in listOf(RealtimeCoverage.Scope.ACCOUNT, RealtimeCoverage.Scope.ROOM, RealtimeCoverage.Scope.DIRECTORY, RealtimeCoverage.Scope.PRESENCE, RealtimeCoverage.Scope.TYPING)) assertTrue(tracker.accept(decode(wire(scope), 7)))
        val original = tracker.snapshot(); assertEquals(5, original.scopes.size)
        val value = wire(RealtimeCoverage.Scope.TYPING)
        assertFalse(tracker.accept(decode(value, 7)))
        value.setRevision(2).setState(RealtimeCoverage.State.ENDED).setReason(RealtimeCoverage.Reason.CANCELLED)
        assertTrue(tracker.accept(decode(value, 7))); assertEquals(4, tracker.snapshot().scopes.size)
        value.setRevision(3).setState(RealtimeCoverage.State.READY).setReason(RealtimeCoverage.Reason.REASON_UNSPECIFIED)
        assertFalse(tracker.accept(decode(value, 7)))
        value.setScopeGeneration(2); assertTrue(tracker.accept(decode(value, 7)))
        value.setRevision(4).setScopeGeneration(1); assertFalse(tracker.accept(decode(value, 7)))
        assertFailsWith<IllegalArgumentException> { tracker.accept(decode(value, 8)) }
        tracker.clear(); assertTrue(tracker.snapshot().scopes.isEmpty()); assertEquals(5, original.scopes.size)
    }
    @Test fun `fixed baseline cannot be raised by duplicate ready but new scope may replace it`() {
        val tracker = RealtimeCoverageTracker(1); val value = wire()
        tracker.accept(decode(value)); val old = tracker.room(1)
        value.setRevision(2).setHighWatermark(11)
        assertFailsWith<ClientFailure.Protocol> { tracker.accept(decode(value)) }
        assertEquals(old, tracker.room(1)); assertNull(tracker.room(2))
        value.setScopeGeneration(2); assertTrue(tracker.accept(decode(value)))
        assertEquals(11, tracker.room(1)!!.baselineHead)
    }
    private fun SSLSocket.send(value: Envelope.Builder) {
        outputStream.write(FrameCodec.encode(value.setProtocolVersion(FrameCodec.VERSION).build())); outputStream.flush()
    }
    @Test fun `late subscriber receives full current coverage and reconnect withdraws prior snapshots`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val sent = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>(); val second = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(wire(RealtimeCoverage.Scope.PRESENCE)))
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(wire()))
                    sent.complete(Unit); release.await()
                }
                peer.accept().use { second.await() }
            }
            try {
                peer.connection.connect(peer.credentials); sent.await()
                val captured = withTimeout(3000) { peer.connection.realtimeCoverage.first { it.scopes.size == 2 } }
                assertEquals(captured, peer.connection.realtimeCoverage.first())
                assertEquals(10, peer.connection.roomProgressScope()!!.baselineHead)
                peer.connection.close(); assertEquals(RealtimeCoverageSnapshot(), peer.connection.realtimeCoverage.value)
                release.complete(Unit); peer.connection.connect(peer.credentials)
                val next = peer.connection.realtimeCoverage.value
                assertTrue(next.scopes.isEmpty()); assertNotEquals(captured.connectionGeneration, next.connectionGeneration)
                assertEquals(2, captured.scopes.size)
            } finally { release.complete(Unit); second.complete(Unit); peer.connection.close(); server.cancelAndJoin() }
        }
    }
    @Test fun `activity stale ready is dropped before legacy events and invalid reason closes TLS`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val end = CompletableDeferred<Unit>(); val invalid = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    val value = wire(RealtimeCoverage.Scope.TYPING)
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(value))
                    end.await()
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(value.setRevision(2).setState(RealtimeCoverage.State.ENDED).setReason(RealtimeCoverage.Reason.CANCELLED)))
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(value.setRevision(3).setState(RealtimeCoverage.State.READY).setReason(RealtimeCoverage.Reason.REASON_UNSPECIFIED)))
                    val heartbeat = FrameCodec.read(socket.inputStream)
                    socket.send(Envelope.newBuilder().setRequestId(heartbeat.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1000000)))
                    invalid.await()
                    socket.send(Envelope.newBuilder().setRealtimeCoverage(value.setRevision(4).setScopeGeneration(2).setReason(RealtimeCoverage.Reason.COVERAGE_LOST)))
                    finish.await()
                }
            }
            val events = kotlinx.coroutines.channels.Channel<RealtimeActivityEvent>(8)
            val collector = launch(start = CoroutineStart.UNDISPATCHED) { peer.connection.activityEvents.collect { events.send(it) } }
            try {
                peer.connection.connect(peer.credentials)
                assertEquals(ActivityCoverageState.Ready, (withTimeout(3000) { events.receive() }.hint as LiveActivityHint.Coverage).state)
                end.complete(Unit)
                peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance()))
                assertEquals(ActivityCoverageState.Ended, (withTimeout(3000) { events.receive() }.hint as LiveActivityHint.Coverage).state)
                assertTrue(events.tryReceive().isFailure); assertTrue(peer.connection.realtimeCoverage.value.scopes.isEmpty())
                invalid.complete(Unit)
                withTimeout(3000) { peer.connection.state.first { !it.connected } }
                assertEquals(RealtimeCoverageSnapshot(), peer.connection.realtimeCoverage.value)
            } finally { end.complete(Unit); invalid.complete(Unit); finish.complete(Unit); peer.connection.close(); collector.cancelAndJoin(); server.cancelAndJoin() }
        }
    }
}
