package com.xmtx.im.swiftprobe

import android.content.Context
import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import java.io.Closeable
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread

/** Contract fixture only: real TLS and canonical generated Protocol, no production accounts. */
internal class Phase3Peer(context: Context, testContext: Context, trusted: Boolean = true, tls12: Boolean = false) : Closeable {
    private val certificate = if (trusted) HeldCertificate.decode(
        context.resources.openRawResource(com.xmtx.im.swiftprobe.R.raw.phase3_test_ca).bufferedReader().use { it.readText() } +
            testContext.assets.open("phase3-test-key.pem").bufferedReader().use { it.readText() })
        else HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
    private val trust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
    val listener = (trust.sslContext().serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
        soTimeout = 15_000
        enabledProtocols = arrayOf(if (tls12) "TLSv1.2" else "TLSv1.3")
    }
    val url get() = "tls://localhost:${listener.localPort}"
    private val live = java.util.concurrent.CopyOnWriteArrayList<SSLSocket>()
    private var worker: Thread? = null
    private val completion = CompletableFuture<Unit>()
    fun run(body: Phase3Peer.() -> Unit) {
        worker = thread(name = "phase3-tls-fixture") {
            try { body(); completion.complete(Unit) } catch (error: Throwable) { completion.completeExceptionally(error) }
        }
    }
    fun accept(): SSLSocket = (listener.accept() as SSLSocket).also { live.add(it); it.soTimeout = 15_000; it.startHandshake() }
    fun await() { completion.get(20, TimeUnit.SECONDS) }
    fun session() {
        repeat(2) { turn ->
            accept().use { socket ->
                val hello = read(socket, 0)
                assertTrue(hello.hasClientHello())
                send(socket, hello.requestId, Envelope.newBuilder().setServerHello(ServerHello.newBuilder()
                    .setServerTimeMs(System.currentTimeMillis()).setSelectedProtocolVersion(VERSION).setSelectedCapabilityProfile("base")
                    .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(65536)))
                val auth = read(socket)
                assertEquals("phase3-fixture-access", auth.authenticate.accessToken)
                assertEquals(DEVICE, auth.authenticate.deviceId)
                send(socket, auth.requestId, Envelope.newBuilder().setAuthenticated(Authenticated.newBuilder()
                    .setUserId(USER).setDeviceId(DEVICE).setSelectedCapabilityProfile("base")
                    .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(65536)))
                var acknowledged = false
                while (!acknowledged) {
                    val request = read(socket)
                    when {
                        request.hasHeartbeat() -> send(socket, request.requestId, Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(System.currentTimeMillis())))
                        request.hasSyncPull() -> {
                            assertEquals(if (turn == 0) "" else "phase3-token-1", request.syncPull.syncToken)
                            val sequence = turn + 1L
                            val payload = """{"target_user_id":"00000000-0000-0000-0000-000000000703","revision":$sequence}"""
                            send(socket, request.requestId, Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder()
                                .setGeneration(1).setCapabilityProfile("base").setNextSyncToken("phase3-token-$sequence")
                                .setSyncReceipt("phase3-receipt-$sequence").addRecords(SyncRecord.newBuilder()
                                    .setUserSyncSequence(sequence).setSourceEventId("00000000-0000-0000-0000-00000000071$sequence")
                                    .setProjectionKind("contact_alias").setPayload(ByteString.copyFromUtf8(payload)))))
                        }
                        request.hasSyncAck() -> {
                            assertEquals(turn + 1L, request.syncAck.highestContiguousSequence)
                            assertEquals("phase3-receipt-${turn + 1}", request.syncAck.syncReceipt)
                            send(socket, request.requestId, Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()))
                            acknowledged = true
                        }
                        else -> error("unexpected command ${request.bodyCase}")
                    }
                }
                if (turn == 0) {
                    // Next heartbeat is left unanswered: deterministic remote EOF after durable ACK.
                    val heartbeat = read(socket); assertTrue(heartbeat.hasHeartbeat())
                } else {
                    while (true) {
                        val request = try { read(socket) } catch (_: java.io.EOFException) { break }
                        assertTrue(request.hasHeartbeat())
                        send(socket, request.requestId, Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(System.currentTimeMillis())))
                    }
                }
            }
        }
    }
    override fun close() { listener.close(); live.forEach { runCatching { it.close() } }; worker?.join(2000) }
    companion object {
        const val VERSION = 55
        const val USER = "00000000-0000-0000-0000-000000000701"
        const val DEVICE = "00000000-0000-0000-0000-000000000702"
        fun read(socket: SSLSocket, version: Int = VERSION): Envelope {
            val input = DataInputStream(socket.inputStream)
            assertEquals(0x494D, input.readUnsignedShort()); assertEquals(version, input.readUnsignedByte())
            assertEquals(0, input.readUnsignedByte()); val command = input.readUnsignedShort()
            val id = input.readLong(); val size = input.readInt(); require(size in 0..65536)
            val bytes = ByteArray(size); input.readFully(bytes)
            return Envelope.parseFrom(bytes).also {
                assertEquals(id, it.requestId); assertEquals(version, it.protocolVersion); assertEquals(command(it), command)
            }
        }
        private fun command(envelope: Envelope) = envelope.bodyCase.number.let { if (it in 10..15) it - 9 else it }
        fun send(socket: SSLSocket, id: Long, builder: Envelope.Builder) {
            val envelope = builder.setProtocolVersion(VERSION).setRequestId(id).build()
            val payload = envelope.toByteArray()
            socket.outputStream.write(ByteBuffer.allocate(18 + payload.size).putShort(0x494D).put(VERSION.toByte()).put(0)
                .putShort(command(envelope).toShort()).putLong(id).putInt(payload.size).put(payload).array())
        }
    }
}
