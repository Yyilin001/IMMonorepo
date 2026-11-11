package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal class MemorySecrets : SecretStore {
    var value: String? = null
    var failWrite = false
    override suspend fun read() = value
    override suspend fun write(value: String) { if (failWrite) throw IOException(); this.value = value }
    override suspend fun delete() { value = null }
}
internal class FakeAccount : AccountTransport {
    val requests = mutableListOf<Pair<String, JsonObject>>()
    var failure: Exception? = null
    var accessExpiry = 100_000L
    var device = "00000000-0000-0000-0000-000000000001"
    override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
        requests += path to payload
        failure?.let { throw it }
        if (path.endsWith("assertion") || path.endsWith("register")) return buildJsonObject { put("accountAssertion", "assertion") }
        if (path.endsWith("cancel-registration") || path.endsWith("revoke")) return buildJsonObject { }
        if (path == "/v2/device-credentials") device = payload.string("deviceID")
        return buildJsonObject {
            put("userID", "user"); put("deviceID", device); put("accessToken", "sensitive-access")
            put("accessTokenExpiresAtMilliseconds", accessExpiry); put("refreshCredential", "sensitive-refresh")
            put("revocationCredential", "imv2-revoke-v1." + "A".repeat(43)); put("revocationCredentialExpiresAtMilliseconds", 1000000000L)
            payload["cancellation"]?.let { put("registrationCancellation", it) }
        }
    }
}
class AuthTests {
    @Test fun `registration journal precedes issuance and uses nested cancellation device`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        val credentials = session.login("account", "password123456")
        val issue = api.requests.last().second
        assertEquals(issue["deviceID"], issue["cancellation"]!!.jsonObject["deviceID"]!!.jsonObject["rawValue"])
        assertEquals(credentials, session.current()); assertFalse(store.value!!.contains("password123456"))
        assertFalse(credentials.toString().contains("sensitive"))
    }
    @Test fun `storage failure prevents any credential issuance`() = runTest {
        val store = MemorySecrets().apply { failWrite = true }; val api = FakeAccount()
        assertFailsWith<IOException> { AuthSession(store, api) { 0 }.login("account", "password123456") }
        assertTrue(api.requests.isEmpty())
    }
    @Test fun `failed registration resumes stable device operation and proof after restart`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount().apply { failure = IOException() }
        assertFailsWith<IOException> { AuthSession(store, api) { 0 }.login("account", "password123456") }
        val pending = Json.parseToJsonElement(store.value!!).jsonObject["registration"]
        api.failure = null
        AuthSession(store, api) { 0 }.login("account", "password123456")
        assertEquals(pending!!.jsonObject["operation"], api.requests.last().second["operationID"])
    }
    @Test fun `concurrent refresh shares durable successor and retry identity`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount().apply { accessExpiry = 1 }
        AuthSession(store, api) { 0 }.login("account", "password123456")
        api.failure = IOException()
        assertFailsWith<IOException> { AuthSession(store, api) { 0 }.access() }
        val id = api.requests.last().second["operationID"]
        api.failure = null; api.accessExpiry = 1_000_000
        val restored = AuthSession(store, api) { 0 }
        coroutineScope { List(10) { async { restored.access() } }.awaitAll() }
        assertEquals(2, api.requests.count { it.first.endsWith("refresh") })
        assertEquals(id, api.requests.last().second["operationID"])
    }
    @Test fun `terminal refresh rejection prevents session resurrection`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount().apply { accessExpiry = 1 }
        val session = AuthSession(store, api) { 0 }; session.login("account", "password123456")
        api.failure = ClientFailure.Http(401)
        assertFailsWith<ClientFailure.Http> { session.access() }
        assertNull(session.current()); assertTrue(session.hasCleanup())
        assertFailsWith<ClientFailure.SignedOut> { session.access() }
    }
    @Test fun `gateway rejection refreshes a locally unexpired token once`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        val first = session.login("account", "password123456")
        api.accessExpiry = 200_000
        val successor = session.access(rejectedAccess = first)
        assertNotEquals(first, successor)
        assertEquals(successor, session.access(rejectedAccess = first))
        assertEquals(1, api.requests.count { it.first.endsWith("refresh") })
    }
    @Test fun `offline logout remains durable and replays same revocation operation`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        session.login("account", "password123456"); api.failure = IOException()
        assertFailsWith<IOException> { session.logout() }
        val operation = api.requests.last().second["operationID"]
        assertNull(session.current()); api.failure = null
        AuthSession(store, api) { 0 }.logout()
        assertEquals(operation, api.requests.last().second["operationID"]); assertNull(store.value)
    }
}
