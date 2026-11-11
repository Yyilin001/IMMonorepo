package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RoomSubscriptionsTlsTests {
    private fun SSLSocket.ack(value: Envelope) {
        outputStream.write(FrameCodec.encode(Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(value.requestId)
            .setAcknowledged(Acknowledged.getDefaultInstance()).build())); outputStream.flush()
    }
    @Test fun `real TLS fresh connection with same epoch restores typing subscription without replaying publication`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { old -> RealtimeReceiveTests.Peer().use { next ->
            val room = RoomId("00000000-0000-0000-0000-000000000002")
            val oldFinish = CompletableDeferred<Unit>(); val nextFinish = CompletableDeferred<Unit>(); val unsubscribed = CompletableDeferred<Unit>()
            val firstServer = async(Dispatchers.IO) {
                old.accept().use { socket ->
                    val subscription = FrameCodec.read(socket.inputStream); assertTrue(subscription.hasSubscribeTyping()); socket.ack(subscription)
                    val positive = FrameCodec.read(socket.inputStream); assertTrue(positive.hasSetTypingState()); assertTrue(positive.setTypingState.isTyping); socket.ack(positive)
                    oldFinish.await()
                }
            }
            val secondServer = async(Dispatchers.IO) {
                next.accept().use { socket ->
                    val subscription = FrameCodec.read(socket.inputStream); assertTrue(subscription.hasSubscribeTyping()); socket.ack(subscription)
                    // The existing channel cleanup sends a defensive false before unsubscribe.
                    // A retained positive publication must never appear on this new connection.
                    val stop = FrameCodec.read(socket.inputStream); assertTrue(stop.hasSetTypingState()); assertFalse(stop.setTypingState.isTyping); socket.ack(stop)
                    val release = FrameCodec.read(socket.inputStream); assertTrue(release.hasUnsubscribeTyping()); socket.ack(release)
                    unsubscribed.complete(Unit); nextFinish.await()
                }
            }
            val owner = RoomSubscriptions(UserId("user"), this)
            fun ports(peer: RealtimeReceiveTests.Peer): RoomSubscriptionConnection {
                val epoch = requireNotNull(peer.connection.authenticatedEpoch)
                val events = RoomEventSubscriptionCoordinator(epoch, RoomEventSubscriptionClient(peer.connection), peer.connection.state,
                    peer.connection.syncEvents, this, { true }, { 0 })
                val activity = LiveActivitySubscriptionCoordinator(epoch, LiveActivityClient(peer.connection), peer.connection.activityEvents,
                    peer.connection.state, this, peer.connection::close)
                return RoomSubscriptionConnection(epoch, peer.connection.state, events, activity, peer.connection::close)
            }
            try {
                val lease = owner.acquire(room, persistentSetOf(RoomSubscriptionChannel.Typing))
                old.connection.connect(old.credentials); val oldEpoch = old.connection.authenticatedEpoch
                val firstId = owner.attach(ports(old))
                withTimeout(3000) { lease.state.first { it.status == RoomSubscriptionStatus.Subscribed } }
                owner.setTyping(lease, firstId, true)
                owner.detach(firstId); oldFinish.complete(Unit); firstServer.await()
                assertEquals(RoomSubscriptionSnapshot(room), lease.state.value)
                next.connection.connect(next.credentials); assertEquals(oldEpoch, next.connection.authenticatedEpoch)
                val nextId = owner.attach(ports(next)); assertNotEquals(firstId, nextId)
                withTimeout(3000) { lease.state.first { it.connectionId == nextId && it.status == RoomSubscriptionStatus.Subscribed } }
                assertFailsWith<RealtimeUnavailableBeforeAdmission> { owner.setTyping(lease, firstId, true) }
                owner.release(lease); withTimeout(3000) { unsubscribed.await() }
                assertTrue(next.connection.state.value.connected)
                nextFinish.complete(Unit); secondServer.await()
            } finally {
                owner.awaitClosed(); oldFinish.complete(Unit); nextFinish.complete(Unit)
                old.connection.close(); next.connection.close(); firstServer.cancelAndJoin(); secondServer.cancelAndJoin()
            }
        } }
    }
}
