package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import javax.net.ssl.SSLSocket
import kotlin.test.*

class LiveActivitySubscriptionTlsTests {
    private fun SSLSocket.ack(value: Envelope) {
        outputStream.write(FrameCodec.encode(Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(value.requestId)
            .setAcknowledged(Acknowledged.getDefaultInstance()).build())); outputStream.flush()
    }
    @Test fun `real TLS typing has one shared subscription and final publisher stop precedes unsubscribe`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val finish = CompletableDeferred<Unit>(); val retired = CompletableDeferred<Unit>()
            val room = RoomId("00000000-0000-0000-0000-000000000002")
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    val subscription = FrameCodec.read(socket.inputStream); assertTrue(subscription.hasSubscribeTyping()); socket.ack(subscription)
                    repeat(2) {
                        val positive = FrameCodec.read(socket.inputStream); assertTrue(positive.hasSetTypingState()); assertTrue(positive.setTypingState.isTyping)
                        assertEquals(room.value, positive.setTypingState.roomId); socket.ack(positive)
                    }
                    val stopped = FrameCodec.read(socket.inputStream); assertTrue(stopped.hasSetTypingState()); assertFalse(stopped.setTypingState.isTyping); socket.ack(stopped)
                    val unsubscribe = FrameCodec.read(socket.inputStream); assertTrue(unsubscribe.hasUnsubscribeTyping()); socket.ack(unsubscribe)
                    retired.complete(Unit); finish.await()
                }
            }
            var owner: LiveActivitySubscriptionCoordinator? = null
            try {
                peer.connection.connect(peer.credentials)
                val epoch = requireNotNull(peer.connection.authenticatedEpoch)
                val shared = LiveActivitySubscriptionCoordinator(epoch, LiveActivityClient(peer.connection), peer.connection.activityEvents,
                    peer.connection.state, this, peer.connection::close); owner = shared
                val first = shared.acquire(room, persistentSetOf(ActivityChannel.Typing)); val second = shared.acquire(room, persistentSetOf(ActivityChannel.Typing))
                withTimeout(3000) { shared.awaitConfirmed(first); shared.awaitConfirmed(second) }
                shared.setTyping(first, epoch, true); shared.setTyping(second, epoch, true)
                shared.setTyping(first, epoch, false); shared.release(first); shared.release(second)
                withTimeout(3000) { retired.await() }; assertTrue(peer.connection.state.value.connected)
                shared.close(); finish.complete(Unit); server.await()
            } finally { owner?.close(); finish.complete(Unit); peer.connection.close(); server.cancelAndJoin() }
        }
    }
}
