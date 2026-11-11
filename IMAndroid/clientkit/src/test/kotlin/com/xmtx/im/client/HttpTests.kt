package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import kotlin.test.*

class HttpTests {
    private fun server(block: (MockWebServer, AccountClient) -> Unit) {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverCert = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.useHttps(serverCert.sslSocketFactory(), false); server.start()
            val http = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
            block(server, AccountClient(server.url("/").toString(), http))
        }
    }
    @Test fun `HTTPS request sets no store and preserves exact JSON`() = server { server, client -> runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody("{\"accountAssertion\":\"assertion\"}"))
        val payload = buildJsonObject { put("password", "exact é e\u0301") }
        assertEquals("assertion", client.post("/v2/account-auth/password/assertion", payload).string("accountAssertion"))
        val request = server.takeRequest()
        assertEquals("no-store", request.getHeader("Cache-Control")); assertEquals("POST", request.method)
        assertEquals(payload.toString(), request.body.readUtf8())
    } }
    @Test fun `password lifecycle requires empty 204 no bearer and never retries HTTP failures`() = server { server, client -> runBlocking {
        val lifecycle = PasswordLifecycleClient(client)
        val device = DeviceId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        for(status in listOf(204, 200, 401, 429, 503)) {
            server.enqueue(MockResponse().setResponseCode(status).setHeader("Retry-After", "23").apply { if(status == 200) setHeader("Content-Type", "application/json").setBody("{}") })
            val error = runCatching { lifecycle.perform(PasswordAction.Change, "account", device, "current-password", "replacement-password") }.exceptionOrNull()
            if(status == 204) assertNull(error) else assertNotNull(error)
            if(status == 429) assertEquals(23L, (error as PasswordLifecycleFailure).retryAfterSeconds)
            val request = server.takeRequest(); assertEquals("/v2/account-auth/password/change", request.path)
            assertEquals("no-store", request.getHeader("Cache-Control")); assertEquals("no-cache", request.getHeader("Pragma")); assertNull(request.getHeader("Authorization"))
        }
        assertEquals(5, server.requestCount)
    } }
    @Test fun `authenticated GET binds device and percent encodes the exact query`() = server { server, client -> runTest {
        val session = AuthSession(MemorySecrets(), FakeAccount()) { 0 }
        val credentials = session.login("account", "password123456")
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody("{}"))
        client.request("/v2/public-identities/resolve", credentials, query = "handle" to "a&b")
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/v2/public-identities/resolve?handle=a%26b", request.path)
        assertEquals(credentials.deviceId.value, request.getHeader("X-IM-Device-ID"))
        assertEquals("Bearer ${credentials.accessToken}", request.getHeader("Authorization"))
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(" ".repeat(8193)))
        assertFailsWith<ClientFailure.Protocol> { client.request("/v2/public-identities/resolve", credentials, maximumBytes = 8192) }
        assertFailsWith<IllegalArgumentException> { client.request("/v2/a#fragment", credentials) }
    } }
    @Test fun `authenticated PUT uses exact verb and never replays after 401`() = server { server, client -> runTest {
        val session = AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials = session.login("account","password123456")
        val api = AuthenticatedApi(session,client,credentials.userId,credentials.deviceId)
        server.enqueue(MockResponse().setResponseCode(401).setHeader("Content-Type","application/json").setBody("{}"))
        val payload = buildJsonObject { put("remarkName","备注") }
        assertEquals(401,api.putWithoutReplay("/v2/profile-presentations/contact-aliases/target",payload).status)
        val request = server.takeRequest();assertEquals("PUT",request.method);assertEquals(payload.toString(),request.body.readUtf8())
        assertEquals(credentials.deviceId.value,request.getHeader("X-IM-Device-ID"));assertEquals("no-store",request.getHeader("Cache-Control"));assertEquals(1,server.requestCount)
    } }
    @Test fun `successful but wrong status cannot settle revocation`() = server { server, client -> runTest {
        server.enqueue(MockResponse().setResponseCode(200).setHeader("Content-Type", "application/json").setBody("{}"))
        assertFailsWith<ClientFailure.Protocol> { client.post("/v2/device-credentials/revoke", buildJsonObject {}, expectedStatus = 204) }
    } }
    @Test fun `profile response allows two MiB but still rejects oversized streamed bodies`() = server { server, client -> runBlocking {
        val session = AuthSession(MemorySecrets(), FakeAccount()) { 0 }
        val credentials = session.login("account", "password123456")
        val payload = buildJsonObject { put("keys",JsonArray(emptyList())) }
        val body = "{\"ignored\":\"" + "a".repeat(1_048_576) + "\"}"
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(body).removeHeader("Content-Length"))
        assertEquals(1_048_576,client.request("/v2/profile-presentations/batch",credentials,payload,maximumBytes = 2_097_152).body.string("ignored").length)
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(" ".repeat(2_097_153)).removeHeader("Content-Length"))
        assertFailsWith<ClientFailure.Protocol> { client.request("/v2/profile-presentations/batch",credentials,payload,maximumBytes = 2_097_152) }
        assertFailsWith<IllegalArgumentException> { client.request("/v2/profile-presentations/batch",credentials,payload,maximumBytes = 2_097_153) }
        assertEquals(2,server.requestCount)
    } }
    @Test fun `redirect is never followed and body is bounded`() = server { server, client -> runTest {
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://example.com"))
        assertEquals(302, assertFailsWith<ClientFailure.Http> { client.post("/v2/test", buildJsonObject {}) }.status)
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(" ".repeat(1_048_577)))
        assertFailsWith<ClientFailure.Protocol> { client.post("/v2/test", buildJsonObject {}) }
        assertEquals(2, server.requestCount)
    } }
    @Test fun `unsafe endpoints and cross host request paths are rejected`() = runTest {
        listOf("http://localhost", "relative", "https://user:secret@localhost", "https://localhost/?token=x").forEach {
            assertFailsWith<IllegalArgumentException> { AccountClient(it) }
        }
        assertFailsWith<IllegalArgumentException> { AccountClient("https://localhost").post("https://example.com/v2/test", buildJsonObject {}) }
    }
}
