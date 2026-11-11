package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RoomEventSubscriptionTlsTests {
    private fun SSLSocket.send(value: Envelope.Builder) {
        outputStream.write(FrameCodec.encode(value.setProtocolVersion(FrameCodec.VERSION).build())); outputStream.flush()
    }
    @Test fun `real TLS shared consumers issue one subscribe and only final release unsubscribes`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val finish = CompletableDeferred<Unit>(); val room = RoomId("00000000-0000-0000-0000-000000000002")
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    val subscribe = FrameCodec.read(socket.inputStream)
                    assertTrue(subscribe.hasGroupEventSubscribe()); assertEquals(room.value, subscribe.groupEventSubscribe.roomId)
                    assertEquals(3, subscribe.groupEventSubscribe.afterRoomSequence)
                    socket.send(Envelope.newBuilder().setRequestId(subscribe.requestId).setGroupEventSubscribed(
                        GroupEventSubscribed.newBuilder().setRoomId(room.value).setHighWatermark(10).setMembershipRevision(1)))
                    val unsubscribe = FrameCodec.read(socket.inputStream)
                    assertTrue(unsubscribe.hasGroupEventUnsubscribe()); assertEquals(room.value, unsubscribe.groupEventUnsubscribe.roomId)
                    socket.send(Envelope.newBuilder().setRequestId(unsubscribe.requestId).setAcknowledged(Acknowledged.getDefaultInstance()))
                    finish.await()
                }
            }
            var owner: RoomEventSubscriptionCoordinator? = null
            try {
                peer.connection.connect(peer.credentials); var cursor = 3L
                val coordinator = RoomEventSubscriptionCoordinator(requireNotNull(peer.connection.authenticatedEpoch), RoomEventSubscriptionClient(peer.connection),
                    peer.connection.state, peer.connection.syncEvents, this, { true }, { cursor })
                owner = coordinator
                val first = coordinator.acquire(room); val second = coordinator.acquire(room)
                coordinator.reconcile(); assertFalse(first.state.value.isCaughtUp); assertEquals(10, first.state.value.baselineHead)
                coordinator.release(first); cursor = 10; coordinator.reconcile()
                assertTrue(second.state.value.isCaughtUp); assertEquals(RoomSubscriptionStatus.Offline, first.state.value.status)
                coordinator.release(second); coordinator.reconcile(); assertTrue(peer.connection.state.value.connected)
                finish.complete(Unit); server.await()
            } finally { finish.complete(Unit); owner?.close(); peer.connection.close(); server.cancelAndJoin() }
        }
    }
}
