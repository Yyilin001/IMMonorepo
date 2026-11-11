package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.io.DataInputStream
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RealtimeTests {
    @Test fun `real TLS handshake repeats identity and suppresses presence then correlates requests`() = runBlocking<Unit> {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTrust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val listener = serverTrust.sslContext().serverSocketFactory.createServerSocket(0) as SSLServerSocket
        listener.soTimeout = 10_000
        val device = DeviceId("00000000-0000-0000-0000-000000000001")
        val credentials = Credentials(UserId("user"), device, "token", 100_000, "refresh", "imv2-revoke-v1." + "A".repeat(43), 100_000)
        val connection = RealtimeConnection("localhost", listener.localPort, clientTrust.sslSocketFactory())
        val server = async(Dispatchers.IO) {
            (listener.accept() as SSLSocket).use { socket ->
                socket.soTimeout = 10_000; socket.startHandshake()
                val input = DataInputStream(socket.inputStream)
                assertEquals(0x494D, input.readUnsignedShort()); assertEquals(0, input.readUnsignedByte()); assertEquals(0, input.readUnsignedByte())
                assertEquals(1, input.readUnsignedShort()); val id = input.readLong(); val length = input.readInt()
                val bytes = ByteArray(length); input.readFully(bytes)
                val hello = Envelope.parseFrom(bytes)
                assertEquals(device.value, hello.clientHello.deviceId); assertTrue(hello.clientHello.supportsMessageSendOperations)
                socket.outputStream.write(FrameCodec.encode(Envelope.newBuilder().setRequestId(id).setProtocolVersion(55)
                    .setServerHello(ServerHello.newBuilder().setServerTimeMs(1_000_000).setSelectedProtocolVersion(55).setSelectedCapabilityProfile("base")
                        .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(65_536)).build()))
                val auth = FrameCodec.read(input)
                assertTrue(auth.authenticate.presencePublicationSuppressed); assertEquals("token", auth.authenticate.accessToken)
                socket.outputStream.write(FrameCodec.encode(Envelope.newBuilder().setRequestId(auth.requestId).setProtocolVersion(55)
                    .setAuthenticated(Authenticated.newBuilder().setUserId("user").setDeviceId(device.value).setSelectedCapabilityProfile("base")
                        .setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(65_536)).build()))
                val denied = FrameCodec.read(input)
                assertTrue(denied.hasListRoomMembers())
                socket.outputStream.write(FrameCodec.encode(Envelope.newBuilder().setRequestId(denied.requestId).setProtocolVersion(55)
                    .setError(com.xmtx.imclientkit.generated.im.realtime.v2.Error.newBuilder().setCode("FORBIDDEN")).build()))
                val heartbeat = FrameCodec.read(input)
                assertTrue(heartbeat.hasHeartbeat())
                socket.outputStream.write(FrameCodec.encode(Envelope.newBuilder().setRequestId(heartbeat.requestId).setProtocolVersion(55)
                    .setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1)).build()))
            }
        }
        try {
            connection.connect(credentials)
            assertFailsWith<GatewayFailure> { connection.request(Envelope.newBuilder().setListRoomMembers(ListRoomMembers.newBuilder().setRoomId("private"))) }
            assertTrue(connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())).hasHeartbeatAck())
            server.await()
            connection.close()
            assertFailsWith<java.io.IOException> { connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())) }
        } finally { connection.close(); listener.close(); server.cancelAndJoin() }
    }
}
