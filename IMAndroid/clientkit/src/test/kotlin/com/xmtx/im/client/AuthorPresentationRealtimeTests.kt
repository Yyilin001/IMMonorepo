package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationDelta as WireDelta
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.io.DataInputStream
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.test.*

class AuthorPresentationRealtimeTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val stream="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private val credentials=Credentials(actor,device,"token",100000,"refresh","imv2-revoke-v1."+"A".repeat(43),100000)
    private inner class Peer(val enabled: Boolean=true): AutoCloseable {
        private val certificate=HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        private val serverTrust=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        private val clientTrust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val listener=(serverTrust.sslContext().serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {soTimeout=5000}
        val connection=RealtimeConnection("localhost",listener.localPort,clientTrust.sslSocketFactory(),authorPresentations=enabled)
        fun accept(negotiatedStream: String=stream,authStream: String=negotiatedStream): SSLSocket {
            val socket=(listener.accept() as SSLSocket).apply {soTimeout=5000;startHandshake()}
            try {
                val input=DataInputStream(socket.inputStream)
                assertEquals(0x494D,input.readUnsignedShort());assertEquals(0,input.readUnsignedByte());assertEquals(0,input.readUnsignedByte());assertEquals(1,input.readUnsignedShort())
                val id=input.readLong();val bytes=ByteArray(input.readInt());input.readFully(bytes)
                assertEquals(enabled,Envelope.parseFrom(bytes).clientHello.supportsAuthorPresentationDelta)
                socket.send(Envelope.newBuilder().setRequestId(id).setServerHello(ServerHello.newBuilder().setServerTimeMs(1_000_000).setSelectedProtocolVersion(FrameCodec.VERSION)
                    .setSelectedCapabilityProfile("base").setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD).setAuthorPresentationStreamId(negotiatedStream)))
                val auth=FrameCodec.read(input)
                socket.send(Envelope.newBuilder().setRequestId(auth.requestId).setAuthenticated(Authenticated.newBuilder().setUserId(actor.value).setDeviceId(device.value)
                    .setSelectedCapabilityProfile("base").setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD).setAuthorPresentationStreamId(authStream)))
                return socket
            } catch(error: Exception) {socket.close();throw error}
        }
        override fun close() {connection.close();listener.close()}
    }
    private fun SSLSocket.send(builder: Envelope.Builder) {outputStream.write(FrameCodec.encode(builder.setProtocolVersion(FrameCodec.VERSION).build()));outputStream.flush()}
    private fun delta(view: String,sequence: Long=1,negotiatedStream: String=stream): Envelope.Builder {
        val raw=Json.parseToJsonElement(javaClass.getResourceAsStream("/author-presentation-swift.jsonl")!!.bufferedReader().readLine()).jsonObject
        val payload=JsonObject(raw+mapOf("streamID" to JsonPrimitive(negotiatedStream),"viewID" to JsonPrimitive(view),"sequence" to JsonPrimitive(sequence),"serverViewAgeMilliseconds" to JsonPrimitive(0))).toString().toByteArray()
        return Envelope.newBuilder().setAuthorPresentationDelta(WireDelta.newBuilder().setPayload(ByteString.copyFrom(payload)))
    }
    @Test fun `negotiated start installs inbox before immediate push and end releases an idle waiter`()=runBlocking<Unit> {
        Peer().use {peer->
            val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                val start=FrameCodec.read(socket.inputStream)
                assertTrue(start.hasAuthorPresentationStart())
                socket.send(Envelope.newBuilder().setRequestId(start.requestId).setAuthorPresentationStarted(start.authorPresentationStart))
                socket.send(delta(start.authorPresentationStart.viewId))
                val receipt=FrameCodec.read(socket.inputStream);assertTrue(receipt.hasAuthorPresentationReceipt())
                assertEquals(1,receipt.authorPresentationReceipt.keysCount)
                socket.send(Envelope.newBuilder().setRequestId(receipt.requestId).setAuthorPresentationReceipted(receipt.authorPresentationReceipt))
                val end=FrameCodec.read(socket.inputStream)
                socket.send(Envelope.newBuilder().setRequestId(end.requestId).setAuthorPresentationEnded(AuthorPresentationEnded.newBuilder().setStreamId(stream).setViewId(end.authorPresentationEnd.viewId)))
                release.await()
            }}
            try {
                peer.connection.connect(credentials);assertEquals(stream,peer.connection.state.value.authorStream)
                val current=peer.connection.beginAuthorPresentationView(persistentListOf())
                val client=AuthorPresentationClient(peer.connection);client.start(current.start)
                val received=withTimeout(3000) {peer.connection.nextAuthorPresentationDelta(current)}
                assertEquals(4,received.entries.size)
                client.receipt(AuthorPresentationReceipt(stream,current.start.view,received.sequence,persistentListOf(received.entries[0].key),0))
                val waiting=async(start=CoroutineStart.UNDISPATCHED) {runCatching {peer.connection.nextAuthorPresentationDelta(current)}}
                peer.connection.endAuthorPresentationView(current)
                assertTrue(withTimeout(3000) {waiting.await()}.isFailure)
                client.end(current.start);assertTrue(peer.connection.state.value.connected)
            } finally {release.complete(Unit);peer.connection.close();server.await()}
        }
    }
    @Test fun `cancelled old start drains its exact reply without reactivating the departed view`()=runBlocking<Unit> {
        Peer().use {peer->
            val oldReceived=CompletableDeferred<Unit>();val answerOld=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                val old=FrameCodec.read(socket.inputStream);oldReceived.complete(Unit);answerOld.await()
                socket.send(Envelope.newBuilder().setRequestId(old.requestId).setAuthorPresentationStarted(old.authorPresentationStart))
                socket.send(delta(old.authorPresentationStart.viewId))
                val next=FrameCodec.read(socket.inputStream)
                socket.send(Envelope.newBuilder().setRequestId(next.requestId).setAuthorPresentationStarted(next.authorPresentationStart))
                socket.send(delta(next.authorPresentationStart.viewId,2));release.await()
            }}
            try {
                peer.connection.connect(credentials);val client=AuthorPresentationClient(peer.connection)
                val old=peer.connection.beginAuthorPresentationView(persistentListOf())
                val request=launch {client.start(old.start)};withTimeout(3000) {oldReceived.await()};request.cancelAndJoin()
                peer.connection.endAuthorPresentationView(old);val next=peer.connection.beginAuthorPresentationView(persistentListOf())
                answerOld.complete(Unit);client.start(next.start)
                val received=withTimeout(3000) {peer.connection.nextAuthorPresentationDelta(next)}
                assertEquals(next,received.view);assertEquals(2,received.sequence)
                assertFails {peer.connection.nextAuthorPresentationDelta(old)}
                assertFails {client.interests(AuthorPresentationInterests(stream,old.start.view,1,persistentListOf()))}
                assertTrue(peer.connection.state.value.connected)
            } finally {answerOld.complete(Unit);release.complete(Unit);peer.connection.close();server.await()}
        }
    }
    @Test fun `authentication cannot silently change the negotiated stream`()=runBlocking<Unit> {
        Peer().use {peer->
            val server=async(Dispatchers.IO) {peer.accept(authStream="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF").close()}
            assertFailsWith<ClientFailure.Protocol> {peer.connection.connect(credentials)}
            assertFalse(peer.connection.state.value.connected);assertNull(peer.connection.state.value.authorStream);server.await()
        }
    }
    @Test fun `server cannot enable an unrequested capability and a supporting client can fall back`()=runBlocking<Unit> {
        Peer(false).use {peer->
            val server=async(Dispatchers.IO) {runCatching {peer.accept().close()}}
            assertFailsWith<ClientFailure.Protocol> {peer.connection.connect(credentials)}
            assertFalse(peer.connection.state.value.connected);assertTrue(server.await().isFailure)
        }
        Peer().use {peer->
            val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept(negotiatedStream="").use {release.await()}}
            try {
                peer.connection.connect(credentials);assertNull(peer.connection.state.value.authorStream)
                assertFails {peer.connection.beginAuthorPresentationView(persistentListOf())}
                assertTrue(peer.connection.state.value.connected)
            } finally {release.complete(Unit);peer.connection.close();server.await()}
        }
    }
    @Test fun `old view teardown and control requests cannot affect a newly authenticated connection`()=runBlocking<Unit> {
        Peer().use {peer->
            val nextStream="11111111-1111-1111-1111-111111111111"
            val releaseOld=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {
                peer.accept().use {socket->
                    val start=FrameCodec.read(socket.inputStream);socket.send(Envelope.newBuilder().setRequestId(start.requestId).setAuthorPresentationStarted(start.authorPresentationStart))
                    releaseOld.await()
                }
                peer.accept(negotiatedStream=nextStream).use {socket->
                    val start=FrameCodec.read(socket.inputStream);assertEquals(nextStream,start.authorPresentationStart.streamId)
                    socket.send(Envelope.newBuilder().setRequestId(start.requestId).setAuthorPresentationStarted(start.authorPresentationStart))
                    socket.send(delta(start.authorPresentationStart.viewId,negotiatedStream=nextStream));release.await()
                }
            }
            try {
                peer.connection.connect(credentials);val client=AuthorPresentationClient(peer.connection)
                val old=peer.connection.beginAuthorPresentationView(persistentListOf());client.start(old.start)
                peer.connection.close();releaseOld.complete(Unit);peer.connection.connect(credentials)
                val current=peer.connection.beginAuthorPresentationView(persistentListOf())
                peer.connection.endAuthorPresentationView(old)
                assertFails {client.end(old.start)};assertFails {client.start(old.start)}
                assertFails {client.receipt(AuthorPresentationReceipt(stream,old.start.view,1,persistentListOf(ProfileKey(actor,ProfileContext.Relationship)),0))}
                client.start(current.start)
                assertEquals(current,withTimeout(3000) {peer.connection.nextAuthorPresentationDelta(current)}.view)
                assertEquals(nextStream,peer.connection.state.value.authorStream);assertTrue(peer.connection.state.value.connected)
            } finally {releaseOld.complete(Unit);release.complete(Unit);peer.connection.close();server.await()}
        }
    }
    @Test fun `wrong recipient push closes the connection and discards queued presentation capability`()=runBlocking<Unit> {
        Peer().use {peer->
            val sent=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                val start=FrameCodec.read(socket.inputStream);socket.send(Envelope.newBuilder().setRequestId(start.requestId).setAuthorPresentationStarted(start.authorPresentationStart))
                val bad=delta(start.authorPresentationStart.viewId).build().authorPresentationDelta.payload.toStringUtf8().replace(stream,"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
                socket.send(Envelope.newBuilder().setAuthorPresentationDelta(WireDelta.newBuilder().setPayload(ByteString.copyFromUtf8(bad))))
                sent.complete(Unit);release.await()
            }}
            try {
                peer.connection.connect(credentials);val current=peer.connection.beginAuthorPresentationView(persistentListOf())
                runCatching {AuthorPresentationClient(peer.connection).start(current.start)}
                withTimeout(3000) {sent.await();peer.connection.state.first {!it.connected}}
                assertFails {peer.connection.nextAuthorPresentationDelta(current)}
            } finally {release.complete(Unit);peer.connection.close();server.await()}
        }
    }
    @Test fun `payload and complete frame have independent limits including protobuf unknown fields`() {
        val body=Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setAuthorPresentationDelta(WireDelta.newBuilder().setPayload(ByteString.copyFrom(ByteArray(32768)))).build()
        assertEquals(32768,FrameCodec.read(FrameCodec.encode(body).inputStream()).authorPresentationDelta.payload.size())
        assertFails {FrameCodec.encode(body.toBuilder().setRequestId(1).build())}
        assertFails {FrameCodec.encode(body.toBuilder().setAuthorPresentationDelta(WireDelta.newBuilder().setPayload(ByteString.copyFrom(ByteArray(32769)))).build())}
        val output=java.io.ByteArrayOutputStream();output.write(body.toByteArray())
        com.google.protobuf.CodedOutputStream.newInstance(output).also {it.writeByteArray(999,ByteArray(2048));it.flush()}
        val bytes=output.toByteArray();val over=Envelope.parseFrom(bytes);assertFails {FrameCodec.encode(over)}
        val forged=java.nio.ByteBuffer.allocate(18+bytes.size).putShort(0x494D).put(FrameCodec.VERSION.toByte()).put(0).putShort(121).putLong(0).putInt(bytes.size).put(bytes).array()
        assertFailsWith<ClientFailure.Protocol> {FrameCodec.read(forged.inputStream())}
    }
}
