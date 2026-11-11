package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlin.test.*

class IncrementalSyncTlsTests {
    @Test fun `real TLS bounded reset sends no snapshot request and leaves transport usable`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val server = async(Dispatchers.IO) { peer.accept().use { socket ->
                fun send(id: Long, body: Envelope.Builder) { socket.outputStream.write(FrameCodec.encode(body.setProtocolVersion(FrameCodec.VERSION).setRequestId(id).build()));socket.outputStream.flush() }
                val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull())
                send(pull.requestId,Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder()
                    .setSnapshotId("00000000-0000-0000-0000-000000000002").setGeneration(2).setBaseUserSyncSequence(5).setExpiresAtMs(2_000_000)))
                val next=FrameCodec.read(socket.inputStream);assertTrue(next.hasHeartbeat())
                send(next.requestId,Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_001)))
            } }
            try {
                peer.connection.connect(peer.credentials);val store=MemorySync();val engine=SyncEngine(peer.connection,store)
                val expected=IncrementalSyncResult(1,false,IncrementalSyncStopReason.ResetPending)
                assertEquals(expected,engine.synchronizeIncrementally(4));assertEquals(expected,engine.synchronizeIncrementally(4))
                assertTrue(peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(1))).hasHeartbeatAck())
                assertNotNull(store.pendingReset());assertNull(store.manifest);server.await()
            } finally {peer.connection.close();server.cancelAndJoin()}
        }
    }
}
