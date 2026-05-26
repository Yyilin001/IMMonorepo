package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPAuthAcceptedPayload
import com.xmtx.imclientkit.networking.imtcp.IMTCPAuthErrorPayload
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
    fun packetCodecDecodesMessageEvent() {
        val line = IMTCPPacketCodec.encode(
            type = "message",
            requestID = "request-1",
            payload = com.xmtx.imclientkit.features.im.IMTCPMessagePayloadWire.fromDomain(
                IMTCPMessagePayload(
                    clientMessageID = "client-1",
                    messageID = "message-1",
                    conversationID = "conversation-1",
                    senderUserID = "user-1",
                    serverSequence = 2UL,
                    content = IMMessageContent.plain("hello"),
                ),
            ),
        )

        val event = IMTCPPacketCodec.event(IMTCPPacketCodec.decode(line))

        assertTrue(event is IMTCPConnectionEvent.Message)
        event as IMTCPConnectionEvent.Message
        assertEquals("request-1", event.requestID)
        assertEquals("hello", event.payload.content.previewText)
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
        assertTrue(transport.sentLines.first().contains("\"type\":\"auth\""))
        assertTrue(transport.sentLines.first().contains("access-1"))
        assertTrue(transport.sentLines.last().contains("\"type\":\"message\""))
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
        assertTrue(transport.sentLines[0].contains("old-access"))
        assertTrue(transport.sentLines[1].contains("new-access"))
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

    private fun authOKLine(): String =
        IMTCPPacketCodec.encode(
            type = "auth_ok",
            requestID = null,
            payload = IMTCPAuthAcceptedPayload(
                connectionID = "connection-1",
                userID = "user-1",
                sessionID = "session-1",
                heartbeatIntervalSeconds = 30,
                serverTime = "2026-05-13T00:00:00Z",
            ),
        )

    private fun authErrorLine(): String =
        IMTCPPacketCodec.encode(
            type = "auth_error",
            requestID = null,
            payload = IMTCPAuthErrorPayload("expired", "expired"),
        )
}

private class FakeIMTCPTransport(
    firstConnectionLines: List<String> = emptyList(),
    private val scriptedConnections: List<List<String>> = listOf(firstConnectionLines),
) : IMTCPTransport {
    val sentLines = mutableListOf<String>()
    private var connectCount = 0

    override suspend fun connect(host: String, port: Int): IMTCPTransportConnection {
        val lines = Channel<String>(Channel.UNLIMITED)
        scriptedConnections.getOrElse(connectCount) { emptyList() }.forEach { lines.send(it) }
        connectCount += 1
        return IMTCPTransportConnection(
            lines = lines,
            sendLineHandler = { sentLines += it },
            disconnectHandler = { lines.close() },
        )
    }
}
