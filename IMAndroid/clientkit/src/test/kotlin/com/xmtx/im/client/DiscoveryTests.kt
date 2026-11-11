package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import kotlin.test.*

internal val actorId = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
internal val targetId = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
internal val lookupDevice = DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
internal class FakeEdge(var answer: suspend (String, JsonObject?) -> EdgeResponse) : AuthenticatedTransport {
    var query: Pair<String, String>? = null
    var maximum = 0L
    override suspend fun request(path: String, payload: JsonObject?, query: Pair<String, String>?, maximumBytes: Long): EdgeResponse {
        this.query = query; maximum = maximumBytes
        return answer(path, payload)
    }
}
internal fun resolution() = buildJsonObject {
    put("actorUserID", wireId(actorId.value)); put("deviceID", wireId(lookupDevice.value))
    put("observedAtUnixMilliseconds", 1000); put("serverNowUnixMilliseconds", 2000); put("validUntilUnixMilliseconds", 11000)
    put("identity", buildJsonObject {
        put("userID", wireId(targetId.value)); put("handle", wireId("alice")); put("displayName", " Alice e\u0301 "); put("accountKind", "regular")
    })
}
class DiscoveryTests {
    @Test fun `exact lookup normalizes handle binds audience and subtracts whole round trip`() = runTest {
        var clock = 0L
        val transport = FakeEdge { path, payload ->
            assertEquals("/v2/public-identities/resolve", path); assertNull(payload)
            clock += 2_000_000_000
            EdgeResponse(200, resolution())
        }
        val result = PublicIdentityDirectory(transport, actorId, lookupDevice) { clock }.resolve("@ALICE")
        assertEquals("handle" to "alice", transport.query); assertEquals(8192, transport.maximum)
        assertEquals("Alice é", result.identity.displayName)
        assertEquals(9_000_000_000, result.deadlineNanos)
        assertTrue(result.valid(8_999_999_999)); assertFalse(result.valid(9_000_000_000))
    }
    @Test fun `foreign audience handle or invalid lifetime cannot grant display permission`() = runTest {
        val mutations = listOf(
            resolution() + ("actorUserID" to wireId(targetId.value)),
            resolution() + ("deviceID" to wireId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")),
            resolution() + ("validUntilUnixMilliseconds" to JsonPrimitive(100000)),
            resolution() + ("observedAtUnixMilliseconds" to JsonPrimitive(3000)),
            resolution() + ("identity" to JsonObject(resolution().objectValue("identity") + ("handle" to wireId("Alice"))))
        )
        for (value in mutations) {
            val api = FakeEdge { _, _ -> EdgeResponse(200, JsonObject(value)) }
            assertFailsWith<ClientFailure.Protocol> { PublicIdentityDirectory(api, actorId, lookupDevice) { 0 }.resolve("alice") }
        }
    }
    @Test fun `expired response and unsafe handles are rejected`() = runTest {
        var clock = 0L
        val api = FakeEdge { _, _ -> clock = 10_000_000_000; EdgeResponse(200, resolution()) }
        assertFailsWith<ClientFailure.Protocol> { PublicIdentityDirectory(api, actorId, lookupDevice) { clock }.resolve("alice") }
        listOf(" al", "a-b", "@@alice", "a", "Ａlice", "alice/other").forEach { assertFailsWith<IllegalArgumentException> { PublicHandle(it) } }
    }
    @Test fun `authenticated edge refreshes exact rejection once and drops late signed out response`() = runTest {
        val account = FakeAccount(); val auth = AuthSession(MemorySecrets(), account) { 0 }
        val credentials = auth.login("account", "password123456")
        var calls = 0
        var signOut = false
        val edge = object : EdgeTransport {
            override suspend fun request(path: String, credentials: Credentials, payload: JsonObject?, query: Pair<String, String>?, maximumBytes: Long): EdgeResponse {
                calls++
                if (signOut) auth.logout()
                return EdgeResponse(if (calls == 1) 401 else 200, buildJsonObject { })
            }
        }
        val api = AuthenticatedApi(auth, edge, credentials.userId, credentials.deviceId)
        assertEquals(200, api.request("/v2/test").status)
        assertEquals(2, calls); assertEquals(1, account.requests.count { it.first.endsWith("refresh") })
        signOut = true
        assertFailsWith<ClientFailure.SignedOut> { api.request("/v2/test") }
    }
}
