package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConnectionStatus
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationCaching
import com.xmtx.imclientkit.features.im.IMConversationMessage
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import com.xmtx.imclientkit.features.im.IMMessageDirection
import com.xmtx.imclientkit.features.im.IMMessageStreamLifecycleState
import com.xmtx.imclientkit.features.im.IMMessageStreamState
import com.xmtx.imclientkit.features.im.IMRuntimeController
import com.xmtx.imclientkit.features.im.withMessageStreamState
import com.xmtx.imclientkit.networking.JsonConfiguration
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPAuthAcceptedPayload
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.networking.imtcp.IMTCPPacketCodec
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransport
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransportConnection
import com.xmtx.imclientkit.persistence.InMemoryTokenStore
import com.xmtx.imclientkit.persistence.InMemoryUserSessionCache
import com.xmtx.imclientkit.persistence.TokenSnapshot
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.TestScope
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class IMRuntimeControllerTests {
    @Test
    fun restoreCachedActiveStreamFetchesSnapshotAndAppliesResponse() = runTest {
        val requests = mutableListOf<String>()
        val controller = runtimeController(
            requests = requests,
            cacheSnapshot = streamingConversationState(),
            streamSnapshotStatus = { HttpStatusCode.OK },
            scope = this,
        )

        controller.start(USER_ID)
        advanceUntilIdle()

        assertEquals(
            listOf("/api/im/conversations/$CONVERSATION_ID/messages/$MESSAGE_ID/stream"),
            requests.filter { it.endsWith("/stream") },
        )
        val message = controller.conversationStore.state.value.conversations.first().messages.first()
        assertEquals("completed text", message.previewText)
        assertEquals(
            IMMessageStreamLifecycleState.Completed,
            message.streamState?.state,
        )
        controller.stop()
    }

    @Test
    fun stopClearsPendingStreamSnapshotRetryQueue() = runTest {
        var snapshotAttempts = 0
        val controller = runtimeController(
            requests = mutableListOf(),
            cacheSnapshot = streamingConversationState(),
            streamSnapshotStatus = {
                snapshotAttempts += 1
                HttpStatusCode.InternalServerError
            },
            scope = this,
        )

        controller.start(USER_ID)
        advanceUntilSnapshotAttempt { snapshotAttempts }

        controller.stop()
        advanceTimeBy(30_000)
        runCurrent()

        assertEquals(1, snapshotAttempts)
        assertEquals(IMConnectionStatus.Disconnected, controller.conversationStore.state.value.connectionStatus)
    }

    @Test
    fun failedActiveStreamSnapshotRetriesAndEventuallyAppliesResponse() = runTest {
        var snapshotAttempts = 0
        val controller = runtimeController(
            requests = mutableListOf(),
            cacheSnapshot = streamingConversationState(),
            streamSnapshotStatus = {
                snapshotAttempts += 1
                if (snapshotAttempts == 1) HttpStatusCode.ServiceUnavailable else HttpStatusCode.OK
            },
            scope = this,
        )

        controller.start(USER_ID)
        advanceUntilSnapshotAttempt { snapshotAttempts }
        advanceTimeBy(1_000)
        advanceUntilIdle()
        advanceUntilMessagePreview(controller, "completed text")

        assertEquals(2, snapshotAttempts)
        val message = controller.conversationStore.state.value.conversations.first().messages.first()
        assertEquals("completed text", message.previewText)
        assertEquals(
            IMMessageStreamLifecycleState.Completed,
            message.streamState?.state,
        )
        controller.stop()
    }

    private fun TestScope.advanceUntilSnapshotAttempt(
        attempts: () -> Int,
    ) {
        repeat(50) {
            if (attempts() > 0) return
            runCurrent()
            advanceTimeBy(1)
        }
        assertEquals(1, attempts())
    }

    private fun TestScope.advanceUntilMessagePreview(
        controller: IMRuntimeController,
        expectedPreview: String,
    ) {
        repeat(50) {
            val preview = controller.conversationStore.state.value.conversations
                .firstOrNull()
                ?.messages
                ?.firstOrNull()
                ?.previewText
            if (preview == expectedPreview) return
            runCurrent()
            advanceTimeBy(1)
        }
    }

    private fun runtimeController(
        requests: MutableList<String>,
        cacheSnapshot: ConversationListState,
        streamSnapshotStatus: () -> HttpStatusCode,
        scope: kotlinx.coroutines.CoroutineScope,
    ): IMRuntimeController {
        val engine = MockEngine { request ->
            requests += request.url.encodedPath
            when (request.url.encodedPath) {
                "/api/im/conversations" -> respondJson(summaryPage())
                "/api/im/conversations/$CONVERSATION_ID/messages/$MESSAGE_ID/stream" -> {
                    val status = streamSnapshotStatus()
                    if (status == HttpStatusCode.OK) {
                        respondJson(streamSnapshotResponse())
                    } else if (status == HttpStatusCode.ServiceUnavailable) {
                        throw java.io.IOException("temporary network failure")
                    } else {
                        respondJson("""{"message":"temporary failure"}""", status)
                    }
                }
                else -> respondJson("""{"message":"unexpected ${request.url.encodedPath}"}""", HttpStatusCode.InternalServerError)
            }
        }
        val httpClient = HttpClient(engine) {
            expectSuccess = false
            install(ContentNegotiation) {
                json(JsonConfiguration.default)
            }
        }
        val sessionClient = SessionClient(
            network = NetworkEnvironment("http://test.local", "test.local", 9000),
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
            userCache = InMemoryUserSessionCache(AuthUser(USER_ID, "user@example.com")),
            httpClient = httpClient,
        )
        return IMRuntimeController(
            sessionClient = sessionClient,
            conversationStore = IMConversationStore(),
            configuration = IMTCPClientConfiguration(host = "test.local", port = 9000),
            conversationCache = StaticIMConversationCache(cacheSnapshot),
            tcpTransport = AuthOKIMTCPTransport(),
            scope = scope,
        )
    }

    private fun streamingConversationState(): ConversationListState =
        ConversationListState(
            conversations = listOf(
                IMConversation(
                    id = CONVERSATION_ID,
                    summary = conversationSummary(),
                    messages = listOf(
                        IMConversationMessage(
                            id = MESSAGE_ID,
                            conversationID = CONVERSATION_ID,
                            clientMessageID = null,
                            serverMessageID = MESSAGE_ID,
                            senderUserID = USER_ID,
                            serverSequence = 1UL,
                            content = IMMessageContent.Text("partial"),
                            derivedState = buildJsonObject { }.withMessageStreamState(
                                IMMessageStreamState(
                                    streamID = STREAM_ID,
                                    state = IMMessageStreamLifecycleState.Streaming,
                                    lastChunkIndex = 1,
                                    partialText = "partial",
                                    updatedAt = "2026-05-19T00:00:01Z",
                                ),
                            ),
                            direction = IMMessageDirection.Outgoing,
                            createdAt = "2026-05-19T00:00:00Z",
                            deliveryState = IMMessageDeliveryState.Sent,
                        ),
                    ),
                ),
            ),
            selectedConversationID = CONVERSATION_ID,
        )

    private fun conversationSummary(): IMConversationSummaryResponseBody =
        IMConversationSummaryResponseBody(
            id = CONVERSATION_ID,
            title = "AI",
            memberCount = 1,
            memberUserIDs = listOf(USER_ID),
            updatedAt = "2026-05-19T00:00:00Z",
        )

    private fun summaryPage(): String =
        """
        {
          "items": [
            {
              "id": "$CONVERSATION_ID",
              "title": "AI",
              "kind": "group",
              "memberCount": 1,
              "memberUserIDs": ["$USER_ID"],
              "lastReadSequence": 0,
              "unreadCount": 0,
              "updatedAt": "2026-05-19T00:00:00Z"
            }
          ],
          "hasMore": false,
          "snapshotToken": "snapshot"
        }
        """.trimIndent()

    private fun streamSnapshotResponse(): String =
        """
        {
          "message": {
            "id": "$MESSAGE_ID",
            "conversationID": "$CONVERSATION_ID",
            "senderUserID": "$USER_ID",
            "serverSequence": 1,
            "content": { "type": "text", "text": "completed text" },
            "derivedState": {
              "streamState": {
                "streamID": "$STREAM_ID",
                "state": "completed",
                "lastChunkIndex": 2,
                "partialText": "completed text",
                "updatedAt": "2026-05-19T00:00:02Z",
                "isAIGenerated": true
              }
            },
            "createdAt": "2026-05-19T00:00:00Z"
          },
          "stream": {
            "streamID": "$STREAM_ID",
            "messageID": "$MESSAGE_ID",
            "conversationID": "$CONVERSATION_ID",
            "chunkIndex": 2,
            "partialTextLength": 14,
            "state": "completed",
            "serverTimestamp": "2026-05-19T00:00:02Z"
          }
        }
        """.trimIndent()

    private fun io.ktor.client.engine.mock.MockRequestHandleScope.respondJson(
        body: String,
        status: HttpStatusCode = HttpStatusCode.OK,
    ) = respond(
        content = body,
        status = status,
        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
    )

    private companion object {
        const val USER_ID = "user-1"
        const val CONVERSATION_ID = "conversation-1"
        const val MESSAGE_ID = "message-1"
        const val STREAM_ID = "stream-1"
    }
}

private class StaticIMConversationCache(
    private val snapshot: ConversationListState,
) : IMConversationCaching {
    override suspend fun loadSnapshot(userID: String): ConversationListState? = snapshot
    override suspend fun saveSnapshot(userID: String, snapshot: ConversationListState) = Unit
    override suspend fun clear(userID: String) = Unit
}

private class AuthOKIMTCPTransport : IMTCPTransport {
    override suspend fun connect(host: String, port: Int): IMTCPTransportConnection {
        val lines = Channel<String>(Channel.UNLIMITED)
        lines.send(
            IMTCPPacketCodec.encode(
                type = "auth_ok",
                requestID = null,
                payload = IMTCPAuthAcceptedPayload(
                    connectionID = "connection-1",
                    userID = "user-1",
                    sessionID = "session-1",
                    heartbeatIntervalSeconds = 30,
                    serverTime = "2026-05-19T00:00:00Z",
                ),
            ),
        )
        return IMTCPTransportConnection(
            lines = lines,
            sendLineHandler = {},
            disconnectHandler = { lines.close() },
        )
    }
}
