package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.contacts.ContactRequestBox
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.networking.APIError
import com.xmtx.imclientkit.networking.JsonConfiguration
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.persistence.InMemoryTokenStore
import com.xmtx.imclientkit.persistence.InMemoryUserSessionCache
import com.xmtx.imclientkit.persistence.TokenSnapshot
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpResponseData
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionClientTests {
    @Test
    fun loginSendsExpectedEndpointAndBody() = runTest {
        var captured: HttpRequestData? = null
        val client = sessionClient { request ->
            captured = request
            respondJson(authResponse(accessToken = "access-1", refreshToken = "refresh-1"))
        }

        val user = client.login("a@example.com", "secret")

        assertEquals("user-1", user.id)
        assertEquals("/api/auth/login", captured?.url?.encodedPath)
        assertEquals(HttpMethod.Post, captured?.method)
        val body = captured?.bodyText().orEmpty()
        assertTrue(body.contains("\"email\":\"a@example.com\""))
        assertTrue(body.contains("\"password\":\"secret\""))
    }

    @Test
    fun authorizedRequestRefreshesAfterUnauthorizedAndRetries() = runTest {
        val requests = mutableListOf<HttpRequestData>()
        val tokenStore = InMemoryTokenStore(TokenSnapshot("old-access", "refresh-1"))
        val userCache = InMemoryUserSessionCache(AuthUser("user-1", "a@example.com"))
        val client = sessionClient(tokenStore = tokenStore, userCache = userCache) { request ->
            requests += request
            when (requests.size) {
                1 -> respond("", HttpStatusCode.Unauthorized)
                2 -> respondJson(authResponse(accessToken = "new-access", refreshToken = "refresh-2"))
                else -> respondJson("""{"id":"user-1","email":"a@example.com","displayName":"Alice"}""")
            }
        }

        val user = client.fetchMe()

        assertEquals("Alice", user.displayName)
        assertEquals("/api/me", requests[0].url.encodedPath)
        assertEquals("Bearer old-access", requests[0].headers[HttpHeaders.Authorization])
        assertEquals("/api/auth/refresh", requests[1].url.encodedPath)
        assertEquals("/api/me", requests[2].url.encodedPath)
        assertEquals("Bearer new-access", requests[2].headers[HttpHeaders.Authorization])
    }

    @Test
    fun refreshFailureClearsSession() = runTest {
        val tokenStore = InMemoryTokenStore(TokenSnapshot("old-access", "refresh-1"))
        val userCache = InMemoryUserSessionCache(AuthUser("user-1", "a@example.com"))
        val client = sessionClient(tokenStore = tokenStore, userCache = userCache) { request ->
            when (request.url.encodedPath) {
                "/api/me" -> respond("", HttpStatusCode.Unauthorized)
                else -> respondJson("""{"message":"refresh failed"}""", HttpStatusCode.Unauthorized)
            }
        }

        runCatching { client.fetchMe() }
            .onFailure { assertTrue(it is APIError.AuthenticationExpired) }

        assertNull(tokenStore.load())
        assertNull(userCache.load())
    }

    @Test
    fun restoreSessionReturnsSignedInWhenCachedAndFetchMeFailsForNetwork() = runTest {
        val cachedUser = AuthUser("user-1", "cached@example.com")
        val client = sessionClient(
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
            userCache = InMemoryUserSessionCache(cachedUser),
        ) {
            throw java.io.IOException("offline")
        }

        val result = client.restoreSession()

        assertEquals(RestoreResult.Authenticated(cachedUser), result)
    }

    @Test
    fun messageContentDecodesTypedTextPayload() {
        val message = JsonConfiguration.default.decodeFromString<IMConversationMessageResponseBody>(
            """
            {
              "id": "message-1",
              "conversationID": "conversation-1",
              "senderUserID": "user-1",
              "serverSequence": 7,
              "content": { "type": "rich_text", "body": { "text": "hello", "entities": [] } },
              "derivedState": {},
              "createdAt": "2026-05-13T00:00:00Z"
            }
            """.trimIndent(),
        )

        assertEquals("hello", message.previewText)
        assertEquals(7, message.serverSequence)
    }

    @Test
    fun fetchContactsSendsExpectedEndpoint() = runTest {
        var captured: HttpRequestData? = null
        val client = sessionClient(
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
        ) { request ->
            captured = request
            respondJson("""[]""")
        }

        client.fetchContacts()

        assertEquals("/api/contacts", captured?.url?.encodedPath)
        assertEquals(HttpMethod.Get, captured?.method)
        assertEquals("Bearer access", captured?.headers?.get(HttpHeaders.Authorization))
    }

    @Test
    fun contactRequestsIncludeBoxQuery() = runTest {
        var captured: HttpRequestData? = null
        val client = sessionClient(
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
        ) { request ->
            captured = request
            respondJson("""[]""")
        }

        client.fetchContactRequests(ContactRequestBox.Incoming)

        assertEquals("/api/contact-requests", captured?.url?.encodedPath)
        assertEquals("incoming", captured?.url?.parameters?.get("box"))
    }

    @Test
    fun createConversationSendsExpectedBody() = runTest {
        var captured: HttpRequestData? = null
        val client = sessionClient(
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
        ) { request ->
            captured = request
            respondJson(conversationSummary("conversation-1"))
        }

        client.createIMConversation(
            kind = IMConversationKind.Group,
            title = "Project",
            memberEmails = listOf("b@example.com", "c@example.com"),
        )

        assertEquals("/api/im/conversations", captured?.url?.encodedPath)
        assertEquals(HttpMethod.Post, captured?.method)
        val body = captured?.bodyText().orEmpty()
        assertTrue(body.contains("\"kind\":\"group\""))
        assertTrue(body.contains("\"title\":\"Project\""))
        assertTrue(body.contains("\"memberEmails\":[\"b@example.com\",\"c@example.com\"]"))
    }

    @Test
    fun fetchMembersSendsExpectedEndpointAndQuery() = runTest {
        var captured: HttpRequestData? = null
        val client = sessionClient(
            tokenStore = InMemoryTokenStore(TokenSnapshot("access", "refresh")),
        ) { request ->
            captured = request
            respondJson("""{"items":[],"nextCursor":"next","hasMore":false}""")
        }

        client.fetchIMConversationMembers("conversation-1", cursor = "cursor", limit = 20, query = "alice")

        assertEquals("/api/im/conversations/conversation-1/members", captured?.url?.encodedPath)
        assertEquals("cursor", captured?.url?.parameters?.get("cursor"))
        assertEquals("20", captured?.url?.parameters?.get("limit"))
        assertEquals("alice", captured?.url?.parameters?.get("q"))
    }

    private fun sessionClient(
        tokenStore: InMemoryTokenStore = InMemoryTokenStore(),
        userCache: InMemoryUserSessionCache = InMemoryUserSessionCache(),
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): SessionClient {
        val engine = MockEngine { request -> handler(request) }
        val httpClient = HttpClient(engine) {
            expectSuccess = false
            install(ContentNegotiation) {
                json(JsonConfiguration.default)
            }
        }
        return SessionClient(
            network = NetworkEnvironment(
                apiBaseUrl = "http://test.local",
                imTcpHost = "test.local",
                imTcpPort = 9000,
            ),
            tokenStore = tokenStore,
            userCache = userCache,
            httpClient = httpClient,
        )
    }

    private fun MockRequestHandleScope.respondJson(
        body: String,
        status: HttpStatusCode = HttpStatusCode.OK,
    ) = respond(
        content = body,
        status = status,
        headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
    )

    private fun authResponse(accessToken: String, refreshToken: String): String =
        """
        {
          "accessToken": "$accessToken",
          "expiresIn": 3600,
          "refreshToken": "$refreshToken",
          "refreshExpiresIn": 7200,
          "user": {
            "id": "user-1",
            "email": "a@example.com",
            "displayName": "Alice"
          }
        }
        """.trimIndent()

    private fun conversationSummary(id: String): String =
        """
        {
          "id": "$id",
          "title": "Project",
          "kind": "group",
          "memberCount": 2,
          "memberUserIDs": [],
          "lastReadSequence": 0,
          "unreadCount": 0,
          "updatedAt": "2026-05-13T00:00:00Z"
        }
        """.trimIndent()

    private fun HttpRequestData.bodyText(): String =
        when (val content = body) {
            is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
            is OutgoingContent.ReadChannelContent -> "<stream>"
            is OutgoingContent.WriteChannelContent -> "<stream>"
            is OutgoingContent.NoContent -> ""
            is OutgoingContent.ProtocolUpgrade -> "<upgrade>"
        }
}
