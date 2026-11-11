package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.test.*

/** Real TLS and wall-clock coroutine deadlines; virtual time cannot drive an OS socket. */
class RealtimeReceiveTests {
    internal class Peer(timeout: Long = 2_000, maximumPending: Int = 16) : Closeable {
        private val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        private val trust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        private val clientTrust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val listener = (trust.sslContext().serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply { soTimeout = 5_000 }
        val connection = RealtimeConnection("localhost", listener.localPort, clientTrust.sslSocketFactory(), timeout, maximumPending)
        private val device = DeviceId("00000000-0000-0000-0000-000000000001")
        val credentials = Credentials(UserId("user"), device, "token", 100_000, "refresh", "imv2-revoke-v1." + "A".repeat(43), 100_000)
        fun accept(serverTime: Long = 1_000_000, rejectAuthentication: Boolean = false, beforeAuthenticated: (() -> Unit)? = null): SSLSocket {
            val socket = (listener.accept() as SSLSocket).apply { soTimeout = 5_000; startHandshake() }
            try {
                val input = DataInputStream(socket.inputStream)
                assertEquals(0x494D, input.readUnsignedShort()); assertEquals(0, input.readUnsignedByte())
                assertEquals(0, input.readUnsignedByte()); assertEquals(1, input.readUnsignedShort())
                val id = input.readLong(); val bytes = ByteArray(input.readInt()); input.readFully(bytes)
                assertTrue(Envelope.parseFrom(bytes).hasClientHello())
                socket.send(Envelope.newBuilder().setRequestId(id).setServerHello(ServerHello.newBuilder().setServerTimeMs(serverTime)
                    .setSelectedProtocolVersion(FrameCodec.VERSION).setSelectedCapabilityProfile("base")
                    .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD)))
                val auth = FrameCodec.read(input)
                assertTrue(auth.authenticate.presencePublicationSuppressed)
                if (rejectAuthentication) {
                    socket.send(Envelope.newBuilder().setRequestId(auth.requestId).setError(com.xmtx.imclientkit.generated.im.realtime.v2.Error.newBuilder().setCode("UNAUTHENTICATED")))
                    return socket
                }
                beforeAuthenticated?.invoke()
                socket.send(Envelope.newBuilder().setRequestId(auth.requestId).setAuthenticated(Authenticated.newBuilder()
                    .setUserId("user").setDeviceId(device.value).setSelectedCapabilityProfile("base")
                    .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD)))
                return socket
            } catch (e: Exception) { socket.close(); throw e }
        }
        override fun close() { connection.close(); listener.close() }
    }
    @Test fun `idle push arrives without a poll and interleaved push cannot acknowledge command`() = runBlocking<Unit> {
        Peer().use { peer ->
            val started = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    started.await()
                    socket.send(typing("first"))
                    val request = FrameCodec.read(socket.inputStream)
                    socket.send(typing("second"))
                    socket.send(Envelope.newBuilder().setRequestId(request.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
                    release.await()
                }
            }
            val received = Channel<RealtimeActivityEvent>(4)
            val events = launch(start = CoroutineStart.UNDISPATCHED) { peer.connection.activityEvents.collect { received.send(it) } }
            try {
                peer.connection.connect(peer.credentials)
                val epoch = peer.connection.state.value.epoch
                started.complete(Unit)
                val first = withTimeout(3_000) { received.receive() }
                assertEquals(epoch, first.connectionEpoch)
                assertEquals(UserId("first"), (first.hint as LiveActivityHint.Typing).value.user)
                assertTrue(peer.connection.request(heartbeat()).hasHeartbeatAck())
                assertEquals(UserId("second"), ((withTimeout(3_000) { received.receive() }).hint as LiveActivityHint.Typing).value.user)
                assertTrue(peer.connection.state.value.connected)
            } finally { release.complete(Unit); peer.connection.close(); events.cancelAndJoin(); server.await() }
        }
    }
    @Test fun `idle sync and room notifications reach typed consumer without a poll`() = runBlocking<Unit> {
        Peer().use { peer ->
            val ready=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    ready.await()
                    socket.send(Envelope.newBuilder().setSyncAvailable(SyncAvailable.newBuilder().setEventId(1).setHighWatermark(2)))
                    socket.send(Envelope.newBuilder().setGroupEventAvailable(GroupEventAvailable.newBuilder().setRoomId("room").setHighWatermark(3)))
                    release.await()
                }
            }
            val received=Channel<RealtimeSyncEvent>(2)
            val collector=launch(start=CoroutineStart.UNDISPATCHED) {peer.connection.syncEvents.collect {received.send(it)}}
            try {
                peer.connection.connect(peer.credentials);ready.complete(Unit)
                val account=withTimeout(3_000) {received.receive()};val room=withTimeout(3_000) {received.receive()}
                assertEquals(peer.connection.state.value.epoch,account.connectionEpoch)
                assertEquals(RealtimeSyncHint.Account(1,2),account.hint)
                assertEquals(RealtimeSyncHint.Room(RoomId("room"),3),room.hint)
            } finally {release.complete(Unit);peer.connection.close();collector.cancelAndJoin();server.await()}
        }
    }
    @Test fun `account ready and reset in the same TLS write install epoch before resuming caller`()=runBlocking<Unit> {
        Peer().use {peer ->
            val old="00000000-0000-0000-0000-000000000001";val next="00000000-0000-0000-0000-000000000002"
            val server=async(Dispatchers.IO) {
                peer.accept().use {socket ->
                    val start=FrameCodec.read(socket.inputStream);assertTrue(start.hasAccountRoomChangesStart())
                    val ready=Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(start.requestId)
                        .setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(old)).build()
                    val reset=Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION)
                        .setAccountRoomResyncRequired(AccountRoomResyncRequired.newBuilder().setConnectionEpoch(old)).build()
                    socket.outputStream.write(FrameCodec.encode(ready)+FrameCodec.encode(reset)+FrameCodec.encode(reset));socket.outputStream.flush()
                    val restart=FrameCodec.read(socket.inputStream);assertTrue(restart.hasAccountRoomChangesStart())
                    socket.send(Envelope.newBuilder().setRequestId(restart.requestId)
                        .setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(next)))
                    val heartbeat=FrameCodec.read(socket.inputStream);assertTrue(heartbeat.hasHeartbeat())
                    socket.send(Envelope.newBuilder().setRequestId(heartbeat.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
                }
            }
            val changes=Channel<RealtimeSyncEvent>(4)
            val collector=launch(start=CoroutineStart.UNDISPATCHED) {peer.connection.syncEvents.collect {if(it.hint is RealtimeSyncHint.AccountResync) changes.send(it)}}
            try {
                peer.connection.connect(peer.credentials)
                val client=AccountRoomChangesClient(peer.connection)
                assertEquals(old,client.start())
                assertEquals(RealtimeSyncHint.AccountResync(old),withTimeout(3_000) {changes.receive()}.hint)
                assertEquals(next,client.start())
                assertFailsWith<ClientFailure.Protocol> {client.start()}
                assertTrue(peer.connection.request(heartbeat()).hasHeartbeatAck())
                assertTrue(changes.tryReceive().isFailure)
                server.await()
            } finally {peer.connection.close();collector.cancelAndJoin();server.cancelAndJoin()}
        }
    }
    @Test fun `account reset with a foreign epoch closes the connection`()=runBlocking<Unit> {
        Peer().use {peer ->
            val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {
                peer.accept().use {socket ->
                    val start=FrameCodec.read(socket.inputStream)
                    socket.send(Envelope.newBuilder().setRequestId(start.requestId).setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder()
                        .setConnectionEpoch("00000000-0000-0000-0000-000000000001")))
                    release.await()
                    socket.send(Envelope.newBuilder().setAccountRoomResyncRequired(AccountRoomResyncRequired.newBuilder()
                        .setConnectionEpoch("00000000-0000-0000-0000-000000000002")))
                    assertEquals(-1,socket.inputStream.read())
                }
            }
            try {
                peer.connection.connect(peer.credentials);AccountRoomChangesClient(peer.connection).start();release.complete(Unit)
                withTimeout(3_000) {peer.connection.state.first {!it.connected}};server.await()
            } finally {peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `cancelled request drains its late response while another request completes`()=runBlocking<Unit> {
        Peer().use {peer ->
            val firstRead=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                val first=FrameCodec.read(socket.inputStream);firstRead.complete(Unit)
                val second=FrameCodec.read(socket.inputStream)
                socket.send(Envelope.newBuilder().setRequestId(second.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(2)))
                release.await()
                socket.send(Envelope.newBuilder().setRequestId(first.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1)))
                val third=FrameCodec.read(socket.inputStream)
                socket.send(Envelope.newBuilder().setRequestId(third.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(3)))
            }}
            try {
                peer.connection.connect(peer.credentials)
                val first=async {peer.connection.request(heartbeat())};firstRead.await();first.cancelAndJoin()
                assertTrue(peer.connection.state.value.connected)
                assertEquals(2,peer.connection.request(heartbeat()).heartbeatAck.serverTimeMs)
                release.complete(Unit)
                assertEquals(3,peer.connection.request(heartbeat()).heartbeatAck.serverTimeMs)
                server.await()
            } finally {release.complete(Unit);peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `concurrent replies are matched in reverse order and business failure stays local`()=runBlocking<Unit> {
        Peer().use {peer ->
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                val requests=List(8) {FrameCodec.read(socket.inputStream)}
                assertEquals(8,requests.map {it.requestId}.toSet().size)
                for(request in requests.reversed()) {
                    val index=request.heartbeat.clientTimeMs
                    if(index==3L) socket.send(Envelope.newBuilder().setRequestId(request.requestId).setError(com.xmtx.imclientkit.generated.im.realtime.v2.Error.newBuilder().setCode("FORBIDDEN")))
                    else socket.send(Envelope.newBuilder().setRequestId(request.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(index + 1)))
                }
            }}
            try {
                peer.connection.connect(peer.credentials)
                val results=supervisorScope {(0L..7).map {index -> async {runCatching {peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(index)))}}}.awaitAll()}
                results.forEachIndexed {index,result -> if(index==3) assertIs<GatewayFailure>(result.exceptionOrNull()) else assertEquals(index.toLong() + 1,result.getOrThrow().heartbeatAck.serverTimeMs)}
                server.await()
            } finally {peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `cancelled on-wire requests keep admission until reply and cancelled waiters send nothing`()=runBlocking<Unit> {
        Peer(maximumPending=1).use {peer ->
            val read=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                val first=FrameCodec.read(socket.inputStream);read.complete(Unit);release.await()
                socket.send(Envelope.newBuilder().setRequestId(first.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
                val next=FrameCodec.read(socket.inputStream);assertEquals(3,next.heartbeat.clientTimeMs)
                socket.send(Envelope.newBuilder().setRequestId(next.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
            }}
            try {
                peer.connection.connect(peer.credentials)
                val first=async {peer.connection.request(heartbeat())};read.await();first.cancelAndJoin()
                val queued=async(start=CoroutineStart.UNDISPATCHED) {peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(2)))}
                assertFalse(queued.isCompleted);queued.cancelAndJoin()
                val next=async(start=CoroutineStart.UNDISPATCHED) {peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(3)))}
                assertFalse(next.isCompleted);assertTrue(peer.connection.state.value.connected)
                release.complete(Unit);assertTrue(next.await().hasHeartbeatAck());server.await()
            } finally {release.complete(Unit);peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `cancelled on-wire deadline closes all pending requests without replay`()=runBlocking<Unit> {
        Peer(timeout=300).use {peer ->
            val read=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                FrameCodec.read(socket.inputStream);read.complete(Unit);FrameCodec.read(socket.inputStream)
                assertEquals(-1,socket.inputStream.read())
            }}
            try {
                peer.connection.connect(peer.credentials)
                val first=async {peer.connection.request(heartbeat())};read.await();first.cancelAndJoin()
                assertFailsWith<TimeoutCancellationException> {peer.connection.request(heartbeat())}
                assertFalse(peer.connection.state.value.connected);server.await()
            } finally {peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `queued old-session requests cannot migrate to a reconnected socket`()=runBlocking<Unit> {
        Peer(maximumPending=1).use {peer ->
            val read=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {
                peer.accept().use {socket -> FrameCodec.read(socket.inputStream);read.complete(Unit);assertEquals(-1,socket.inputStream.read())}
                peer.accept().use {socket -> val request=FrameCodec.read(socket.inputStream)
                    assertEquals(3,request.heartbeat.clientTimeMs)
                    socket.send(Envelope.newBuilder().setRequestId(request.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))}
            }
            try {supervisorScope {
                peer.connection.connect(peer.credentials);val epoch=peer.connection.state.value.epoch
                val first=async {runCatching {peer.connection.request(heartbeat())}};read.await()
                val queued=async(start=CoroutineStart.UNDISPATCHED) {runCatching {peer.connection.request(heartbeat())}}
                assertFalse(queued.isCompleted);peer.connection.connect(peer.credentials)
                val onWire=first.await().exceptionOrNull();assertIs<IOException>(onWire);assertFalse(onWire is RealtimeUnavailableBeforeAdmission)
                assertIs<RealtimeUnavailableBeforeAdmission>(queued.await().exceptionOrNull())
                peer.connection.close(epoch);assertTrue(peer.connection.state.value.connected)
                assertTrue(peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(3))).hasHeartbeatAck());server.await()
            }} finally {peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `a second account start cannot enter while the first is awaiting ready`()=runBlocking<Unit> {
        Peer().use {peer ->
            val read=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val epoch="00000000-0000-0000-0000-000000000001"
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                val first=FrameCodec.read(socket.inputStream);assertTrue(first.hasAccountRoomChangesStart());read.complete(Unit);release.await()
                socket.send(Envelope.newBuilder().setRequestId(first.requestId).setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(epoch)))
                val next=FrameCodec.read(socket.inputStream);assertTrue(next.hasHeartbeat())
                socket.send(Envelope.newBuilder().setRequestId(next.requestId).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
            }}
            try {
                peer.connection.connect(peer.credentials);val client=AccountRoomChangesClient(peer.connection)
                val first=async {client.start()};read.await()
                assertFailsWith<ClientFailure.Protocol> {client.start()};assertTrue(peer.connection.state.value.connected)
                release.complete(Unit);assertEquals(epoch,first.await());assertTrue(peer.connection.request(heartbeat()).hasHeartbeatAck());server.await()
            } finally {release.complete(Unit);peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `command timeout closes transport without replay`() = runBlocking<Unit> {
        Peer(timeout = 100).use { peer ->
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    assertTrue(FrameCodec.read(socket.inputStream).hasHeartbeat())
                    assertEquals(-1, socket.inputStream.read())
                }
            }
            try {
                peer.connection.connect(peer.credentials)
                assertFailsWith<TimeoutCancellationException> { peer.connection.request(heartbeat()) }
                assertFalse(peer.connection.state.value.connected)
                assertFailsWith<IOException> { peer.connection.request(heartbeat()) }
                server.await()
            } finally { peer.connection.close(); server.cancelAndJoin() }
        }
    }
    @Test fun `unexpected correlation fails pending request and disconnects`() = runBlocking<Unit> {
        Peer().use { peer ->
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    val request = FrameCodec.read(socket.inputStream)
                    socket.send(Envelope.newBuilder().setRequestId(request.requestId + 1).setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()))
                    assertEquals(-1, socket.inputStream.read())
                }
            }
            try {
                peer.connection.connect(peer.credentials)
                assertFailsWith<ClientFailure.Protocol> { peer.connection.request(heartbeat()) }
                assertFalse(peer.connection.state.value.connected)
                server.await()
            } finally { peer.connection.close(); server.cancelAndJoin() }
        }
    }
    @Test fun `malformed idle activity disconnects rather than emitting invalid identity`() = runBlocking<Unit> {
        Peer().use { peer ->
            val ready = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    ready.await(); socket.send(typing("invalid/user"))
                    assertEquals(-1, socket.inputStream.read())
                }
            }
            try {
                peer.connection.connect(peer.credentials); ready.complete(Unit)
                withTimeout(3_000) { peer.connection.state.first { !it.connected } }
                assertFailsWith<IOException> { peer.connection.request(heartbeat()) }
                server.await()
            } finally { peer.connection.close(); server.cancelAndJoin() }
        }
    }
    @Test fun `bounded event overflow ends connection instead of silently retaining stale leases`() = runBlocking<Unit> {
        Peer().use { peer ->
            val ready = CompletableDeferred<Unit>()
            val server = async(Dispatchers.IO) {
                peer.accept().use { socket ->
                    ready.await()
                    // A closed peer may reject the remaining frames once the bounded buffer fills.
                    runCatching { repeat(200) { socket.send(typing("user$it")) } }
                    assertEquals(-1, socket.inputStream.read())
                }
            }
            val first = CompletableDeferred<Unit>()
            val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                peer.connection.activityEvents.collect { first.complete(Unit); awaitCancellation() }
            }
            try {
                peer.connection.connect(peer.credentials); ready.complete(Unit)
                withTimeout(3_000) { first.await(); peer.connection.state.first { !it.connected } }
                assertFailsWith<IOException> { peer.connection.request(heartbeat()) }
                server.await()
            } finally { peer.connection.close(); collector.cancelAndJoin(); server.cancelAndJoin() }
        }
    }
    @Test fun `heartbeat progress uses installed TLS scope and ended scope rejects late ready and ack`()=runBlocking<Unit> {
        Peer().use {peer ->
            val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
            val ready=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            fun coverage(revision:Long,state:RealtimeCoverage.State,reason:RealtimeCoverage.Reason)=Envelope.newBuilder().setRealtimeCoverage(
                RealtimeCoverage.newBuilder().setScope(RealtimeCoverage.Scope.ROOM).setScopeId(room.value)
                    .setScopeGeneration(7).setRevision(revision).setHighWatermark(10).setState(state).setReason(reason))
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                ready.await();socket.send(coverage(1,RealtimeCoverage.State.READY,RealtimeCoverage.Reason.REASON_UNSPECIFIED))
                val first=FrameCodec.read(socket.inputStream)
                val report=first.heartbeat.roomProgressList.single()
                assertEquals(room.value,report.roomId);assertEquals(7,report.scopeGeneration);assertEquals(4,report.appliedRoomSequence)
                val ack=HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).addRoomSubscriptionStates(GroupEventProgressState.newBuilder()
                    .setRoomId(room.value).setScopeGeneration(7).setHighWatermark(20).setAppliedRoomSequence(4).setReady(true))
                socket.send(Envelope.newBuilder().setRequestId(first.requestId).setHeartbeatAck(ack))
                val second=FrameCodec.read(socket.inputStream)
                socket.send(coverage(2,RealtimeCoverage.State.ENDED,RealtimeCoverage.Reason.CANCELLED))
                socket.send(coverage(3,RealtimeCoverage.State.READY,RealtimeCoverage.Reason.REASON_UNSPECIFIED))
                socket.send(Envelope.newBuilder().setRequestId(second.requestId).setHeartbeatAck(ack))
                val third=FrameCodec.read(socket.inputStream);assertEquals(0,third.heartbeat.roomProgressCount)
                socket.send(Envelope.newBuilder().setRequestId(third.requestId).setHeartbeatAck(ack))
                release.await()
            }}
            val events=Channel<RealtimeSyncEvent>(8)
            val collector=launch(start=CoroutineStart.UNDISPATCHED) {peer.connection.syncEvents.collect {events.send(it)}}
            try {
                withTimeout(5000) {
                    peer.connection.connect(peer.credentials);ready.complete(Unit)
                    assertIs<RealtimeSyncHint.Coverage>(events.receive().hint)
                    val heartbeat=HeartbeatClient(peer.connection) {assertEquals(room,it);4}
                    heartbeat.send();assertEquals(RealtimeSyncHint.Room(room,20),events.receive().hint)
                    heartbeat.send();assertEquals(ActivityCoverageState.Ended,(events.receive().hint as RealtimeSyncHint.Coverage).state)
                    assertNull(peer.connection.roomProgressScope())
                    heartbeat.send();assertTrue(events.tryReceive().isFailure)
                    val oldEpoch=peer.connection.authenticatedEpoch!!;peer.connection.close()
                    assertNull(peer.connection.roomProgressScope());assertNull(peer.connection.authenticatedEpoch)
                    assertFailsWith<RealtimeUnavailableBeforeAdmission> {peer.connection.requestHeartbeat(Heartbeat.getDefaultInstance(),oldEpoch)}
                }
            } finally {ready.complete(Unit);release.complete(Unit);peer.connection.close();collector.cancelAndJoin();server.await()}
        }
    }
    @Test fun `TLS coverage cannot redefine ready baseline in same installed generation`()=runBlocking<Unit> {
        Peer().use {peer ->
            val ready=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                ready.await()
                val coverage=RealtimeCoverage.newBuilder().setScope(RealtimeCoverage.Scope.ROOM)
                    .setScopeId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA").setScopeGeneration(1)
                    .setRevision(1).setHighWatermark(10).setState(RealtimeCoverage.State.READY)
                socket.send(Envelope.newBuilder().setRealtimeCoverage(coverage))
                socket.send(Envelope.newBuilder().setRealtimeCoverage(coverage.setRevision(2).setHighWatermark(11)))
                assertEquals(-1,socket.inputStream.read())
            }}
            try {
                peer.connection.connect(peer.credentials);ready.complete(Unit)
                withTimeout(3000) {peer.connection.state.first {!it.connected}}
                assertNull(peer.connection.roomProgressScope());server.await()
            } finally {ready.complete(Unit);peer.connection.close();server.cancelAndJoin()}
        }
    }
    companion object {
        private fun heartbeat() = Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())
        private fun typing(user: String) = Envelope.newBuilder().setTypingStateChanged(TypingStateChanged.newBuilder()
            .setRoomId("room").setUserId(user).setIsTyping(true).setExpiresAtMs(10_000))
        private fun SSLSocket.send(value: Envelope.Builder) {
            outputStream.write(FrameCodec.encode(value.setProtocolVersion(FrameCodec.VERSION).build())); outputStream.flush()
        }
    }
}
