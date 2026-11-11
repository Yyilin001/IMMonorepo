package com.xmtx.im.client

import com.xmtx.im.client.RealtimeReceiveTests.Peer
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RealtimeServerTimeTests {
    private fun SSLSocket.ack(request: Envelope, time: Long) {
        outputStream.write(FrameCodec.encode(Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION)
            .setRequestId(request.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(time)).build()))
        outputStream.flush()
    }
    private fun assertTime(connection: RealtimeConnection, sample: Long) {
        assertTrue(connection.serverTime.now() in sample..sample + 10_000)
    }

    @Test fun `authenticated hello and correlated heartbeat own the clock across reconnect`() = runBlocking<Unit> {
        Peer().use { peer ->
            val release = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept(1_000_000).use { socket ->
                    // An ack answering a non-heartbeat command is not a clock sample.
                    socket.ack(FrameCodec.read(socket.inputStream), 9_000_000)
                    socket.ack(FrameCodec.read(socket.inputStream), 2_000_000)
                    assertEquals(-1, socket.inputStream.read())
                }
                peer.accept(3_000_000).use { release.await() }
            }
            try {
                assertFailsWith<ServerTimeAnchor.Failure> { peer.connection.serverTime.now() }
                peer.connection.connect(peer.credentials)
                assertTime(peer.connection, 1_000_000)
                peer.connection.request(Envelope.newBuilder().setSyncPull(SyncPull.getDefaultInstance()))
                assertTime(peer.connection, 1_000_000)
                peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance()))
                assertTime(peer.connection, 2_000_000)
                val oldEpoch = requireNotNull(peer.connection.authenticatedEpoch)
                peer.connection.close()
                assertFailsWith<ServerTimeAnchor.Failure> { peer.connection.serverTime.now() }
                peer.connection.connect(peer.credentials)
                peer.connection.close(oldEpoch)
                assertTime(peer.connection, 3_000_000)
            } finally { release.complete(Unit); peer.connection.close(); server.await() }
        }
    }

    @Test fun `invalid hello cannot authenticate or provide a time anchor`() = runBlocking<Unit> {
        Peer().use { peer ->
            val server = async(Dispatchers.IO) { runCatching { peer.accept(0).close() } }
            try {
                assertFailsWith<ClientFailure.Protocol> { peer.connection.connect(peer.credentials) }
                assertFalse(peer.connection.state.value.connected)
                assertFailsWith<ServerTimeAnchor.Failure> { peer.connection.serverTime.now() }
                assertTrue(server.await().isFailure)
            } finally { peer.connection.close(); server.cancelAndJoin() }
        }
    }

    @Test fun `invalid heartbeat closes its session and removes old time authority`() = runBlocking<Unit> {
        Peer().use { peer ->
            val release = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) { peer.accept().use { socket ->
                socket.ack(FrameCodec.read(socket.inputStream), -1)
                release.await()
            } }
            try {
                peer.connection.connect(peer.credentials)
                assertFailsWith<ClientFailure.Protocol> { peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())) }
                assertFalse(peer.connection.state.value.connected)
                assertFailsWith<ServerTimeAnchor.Failure> { peer.connection.serverTime.now() }
            } finally { release.complete(Unit); peer.connection.close(); server.await() }
        }
    }
}
