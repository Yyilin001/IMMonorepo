package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.generated.im.realtime.v1.AuthAccepted
import com.xmtx.imclientkit.generated.im.realtime.v1.AuthError
import com.xmtx.imclientkit.generated.im.realtime.v1.ChatDomainEvent
import com.xmtx.imclientkit.generated.im.realtime.v1.ConversationMessage
import com.xmtx.imclientkit.generated.im.realtime.v1.MessageContent
import com.xmtx.imclientkit.generated.im.realtime.v1.MessageCreatedEvent
import com.xmtx.imclientkit.generated.im.realtime.v1.MessageDerivedState
import com.xmtx.imclientkit.generated.im.realtime.v1.Packet
import com.xmtx.imclientkit.generated.im.realtime.v1.RichTextContent
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPClient
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientError
import com.xmtx.imclientkit.networking.imtcp.IMTCPConnectionEvent
import com.xmtx.imclientkit.networking.imtcp.IMTCPPacketCodec
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransport
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransportConnection
import com.xmtx.imclientkit.persistence.InMemoryTokenStore
import com.xmtx.imclientkit.persistence.InMemoryUserSessionCache
import com.xmtx.imclientkit.persistence.TokenSnapshot
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class IMTCPClientTests {
    @Test
    fun packetCodecDecodesDomainEvent() {
        val frame = packetBuilder("request-1")
            .setDomainEvent(
                ChatDomainEvent.newBuilder()
                    .setEventId("event-1")
                    .setEventType("message.created")
                    .setAggregateType("conversation")
                    .setAggregateId("conversation-1")
                    .setAggregateSequence(2UL.toLong())
                    .setOccurredAtMs(1_768_262_400_000)
                    .setMessageCreated(
                        MessageCreatedEvent.newBuilder()
                            .setClientMessageId("client-1")
                            .setMessage(messageProto())
                            .build(),
                    )
                    .build(),
            )
            .build()
            .toByteArray()

        val event = IMTCPPacketCodec.event(IMTCPPacketCodec.decode(frame))

        assertTrue(event is IMTCPConnectionEvent.DomainEvent)
        event as IMTCPConnectionEvent.DomainEvent
        assertEquals("request-1", event.requestID)
        val body = event.payload.body as com.xmtx.imclientkit.features.im.IMTCPChatDomainEventBody.MessageCreated
        assertEquals("hello", body.message.content.previewText)
    }

    @Test
    fun clientAuthenticatesAndSendsMessages() = runTest {
        val transport = FakeIMTCPTransport(listOf(authOKLine()))
        val client = IMTCPClient(
            configuration = configuration(),
            transport = transport,
            accessTokenProvider = { "access-1" },
        )

        val connection = client.connect()
        connection.sendMessage(
            IMTCPMessagePayload(
                clientMessageID = "client-1",
                conversationID = "conversation-1",
                senderUserID = "user-1",
                content = IMMessageContent.plain("hello"),
            ),
            requestID = "send-1",
        )

        assertEquals("connection-1", connection.authentication.connectionID)
        val authPacket = IMTCPPacketCodec.decode(transport.sentFrames.first())
        val sendPacket = IMTCPPacketCodec.decode(transport.sentFrames.last())
        assertEquals(Packet.BodyCase.AUTH, authPacket.bodyCase)
        assertEquals("access-1", authPacket.auth.accessToken)
        assertEquals(Packet.BodyCase.SEND_MESSAGE, sendPacket.bodyCase)
        assertEquals("hello", sendPacket.sendMessage.content.richText.text)
    }

    @Test
    fun sessionClientRefreshesTokenWhenTcpAuthIsRejectedOnce() = runTest {
        val transport = FakeIMTCPTransport(
            scriptedConnections = listOf(
                listOf(authErrorLine()),
                listOf(authOKLine()),
            ),
        )
        val tokenStore = InMemoryTokenStore(TokenSnapshot("old-access", "refresh-1"))
        val sessionClient = SessionClient(
            network = NetworkEnvironment("http://test.local", "test.local", 9000),
            tokenStore = tokenStore,
            userCache = InMemoryUserSessionCache(AuthUser("user-1", "a@example.com")),
            httpClient = HttpClient(
                MockEngine {
                    respond(
                        content = """
                        {
                          "accessToken": "new-access",
                          "expiresIn": 3600,
                          "refreshToken": "refresh-2",
                          "refreshExpiresIn": 7200,
                          "user": {"id":"user-1","email":"a@example.com"}
                        }
                        """.trimIndent(),
                        status = HttpStatusCode.OK,
                        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                },
            ),
        )

        val connection = sessionClient.openIMConnection(configuration(), transport)

        assertEquals("connection-1", connection.authentication.connectionID)
        assertEquals("old-access", IMTCPPacketCodec.decode(transport.sentFrames[0]).auth.accessToken)
        assertEquals("new-access", IMTCPPacketCodec.decode(transport.sentFrames[1]).auth.accessToken)
    }

    @Test(expected = IMTCPClientError.AuthRejected::class)
    fun clientThrowsAuthRejectedForAuthError() = runTest {
        val client = IMTCPClient(
            configuration = configuration(),
            transport = FakeIMTCPTransport(listOf(authErrorLine())),
            accessTokenProvider = { "access-1" },
        )

        client.connect()
    }

    private fun configuration(): IMTCPClientConfiguration =
        IMTCPClientConfiguration(host = "test.local", port = 9000)

    private fun authOKLine(): ByteArray =
        packetBuilder(null)
            .setAuthOk(
                AuthAccepted.newBuilder()
                    .setConnectionId("connection-1")
                    .setUserId("user-1")
                    .setSessionId("session-1")
                    .setHeartbeatIntervalSeconds(30)
                    .setServerTimeMs(1_768_262_400_000)
                    .build(),
            )
            .build()
            .toByteArray()

    private fun authErrorLine(): ByteArray =
        packetBuilder(null)
            .setAuthError(AuthError.newBuilder().setCode("expired").setMessage("expired").build())
            .build()
            .toByteArray()

    private fun packetBuilder(requestID: String?): Packet.Builder =
        Packet.newBuilder()
            .also { if (requestID != null) it.requestId = requestID }
            .setTimestampMs(1_768_262_400_000)
            .setProtocolVersion(4)

    private fun messageProto(): ConversationMessage =
        ConversationMessage.newBuilder()
            .setId("message-1")
            .setConversationId("conversation-1")
            .setSenderUserId("user-1")
            .setClientMessageId("client-1")
            .setServerSequence(2)
            .setContent(
                MessageContent.newBuilder()
                    .setRichText(RichTextContent.newBuilder().setText("hello").build())
                    .build(),
            )
            .setDerivedState(MessageDerivedState.newBuilder().setRecallState("active").build())
            .setCreatedAtMs(1_768_262_400_000)
            .build()
}

private class FakeIMTCPTransport(
    firstConnectionFrames: List<ByteArray> = emptyList(),
    private val scriptedConnections: List<List<ByteArray>> = listOf(firstConnectionFrames),
) : IMTCPTransport {
    val sentFrames = mutableListOf<ByteArray>()
    private var connectCount = 0

    override suspend fun connect(host: String, port: Int): IMTCPTransportConnection {
        val frames = Channel<ByteArray>(Channel.UNLIMITED)
        scriptedConnections.getOrElse(connectCount) { emptyList() }.forEach { frames.send(it) }
        connectCount += 1
        return IMTCPTransportConnection(
            frames = frames,
            sendFrameHandler = { sentFrames += it },
            disconnectHandler = { frames.close() },
        )
    }
}
