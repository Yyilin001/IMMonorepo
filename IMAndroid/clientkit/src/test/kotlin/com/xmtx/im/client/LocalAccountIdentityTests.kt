package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

class LocalAccountIdentityTests {
    @Test fun `expired credentials and pending refresh expose only local identity without writes or network`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount().apply { accessExpiry = 1 }
        AuthSession(store, api) { 0 }.login("account", "password123456")
        api.failure = IOException()
        assertFailsWith<IOException> { AuthSession(store, api) { 0 }.access() }
        val before = store.value; val requests = api.requests.size
        val session = AuthSession(store, api) { 1_000_000 }
        val identity = session.localAccountIdentity()
        assertEquals(UserId("user"), identity.userId)
        assertSame(identity.epoch, session.currentEpoch())
        session.requireLocalIdentity(identity); session.requireLocalIdentityEpoch(identity.epoch)
        assertFailsWith<ClientFailure.SessionInvalidated> { session.requireLocalIdentity(identity.copy(userId = UserId("another"))) }
        assertEquals(before, store.value); assertEquals(requests, api.requests.size)
        assertFalse(identity.toString().contains("sensitive"))
        assertFailsWith<ClientFailure.SessionInvalidated> {
            AuthSession(store, api).requireLocalIdentity(identity)
        }
    }

    @Test fun `token refresh preserves identity but a new lifetime for the same device invalidates old evidence`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        val original = session.login("account", "password123456")
        val identity = session.localAccountIdentity()
        api.accessExpiry = 200_000
        session.access(original, expectedEpoch = identity.epoch)
        assertEquals(identity, session.localAccountIdentity())
        val restoredRecord = store.value
        session.logout(); store.value = restoredRecord
        val replacement = session.localAccountIdentity()
        assertEquals(identity.userId, replacement.userId); assertEquals(identity.deviceId, replacement.deviceId)
        assertNotSame(identity.epoch, replacement.epoch)
        assertFailsWith<ClientFailure.SessionInvalidated> { session.requireLocalIdentity(identity) }
        assertFailsWith<ClientFailure.SessionInvalidated> { session.access(expectedEpoch = identity.epoch) }
    }

    @Test fun `failed logout intent write blocks the current owner before any network cleanup`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        session.login("account", "password123456"); val identity = session.localAccountIdentity()
        val before = store.value; val requests = api.requests.size; store.failWrite = true
        assertFailsWith<IOException> { session.logout() }
        assertEquals(before, store.value); assertEquals(requests, api.requests.size)
        assertNull(session.current()); assertTrue(session.hasCleanup())
        assertFailsWith<ClientFailure.SignedOut> { session.localAccountIdentity() }
        assertFailsWith<ClientFailure.SessionInvalidated> { session.requireLocalIdentity(identity) }
        store.failWrite = false; session.logout()
        assertFalse(session.hasCleanup()); assertNull(store.value)
    }

    @Test fun `a persisted revocation operation blocks local identity even without the boolean flag`() = runTest {
        val store = MemorySecrets(); val api = FakeAccount(); val session = AuthSession(store, api) { 0 }
        session.login("account", "password123456"); val identity = session.localAccountIdentity()
        val previous = Json.parseToJsonElement(requireNotNull(store.value)).jsonObject
        store.value = JsonObject(previous + ("revocationOperation" to JsonPrimitive("pending-revocation"))).toString()
        val requests = api.requests.size; val before = store.value
        assertTrue(session.hasCleanup()); assertNull(session.current())
        assertFailsWith<ClientFailure.SignedOut> { session.localAccountIdentity() }
        assertFailsWith<ClientFailure.SessionInvalidated> { session.requireLocalIdentity(identity) }
        assertFails { session.login("account", "password123456") }
        assertEquals(requests, api.requests.size); assertEquals(before, store.value)
    }

    @Test fun `failed persistence after terminal refresh rejection cannot restore local access`() = runTest {
        val store = MemorySecrets(); val fake = FakeAccount().apply { accessExpiry = 1 }
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                if (path.endsWith("refresh")) { store.failWrite = true; throw ClientFailure.Http(401) }
                return fake.post(path, payload, accessToken, expectedStatus)
            }
        }
        val session = AuthSession(store, api) { 0 }; session.login("account", "password123456")
        val identity = session.localAccountIdentity()
        assertFailsWith<IOException> { session.access() }
        assertNull(session.current()); assertTrue(session.hasCleanup())
        assertFailsWith<ClientFailure.SessionInvalidated> { session.requireLocalIdentityEpoch(identity.epoch) }
    }

    @Test fun `unavailable malformed and cancelled local reads never become successful identities`() = runTest {
        val backing = MemorySecrets(); val api = FakeAccount()
        AuthSession(backing, api) { 0 }.login("account", "password123456")
        var fail = false; var block = false; val entered = CompletableDeferred<Unit>()
        val store = object : SecretStore {
            override suspend fun read(): String? {
                if (fail) throw IOException()
                if (block) { entered.complete(Unit); awaitCancellation() }
                return backing.value
            }
            override suspend fun write(value: String) = error("local read wrote credentials")
            override suspend fun delete() = error("local read deleted credentials")
        }
        val session = AuthSession(store, api); val identity = session.localAccountIdentity(); val requests = api.requests.size
        fail = true; assertFailsWith<IOException> { session.localAccountIdentity() }; fail = false
        assertEquals(identity, session.localAccountIdentity())
        block = true
        val reading = launch { session.localAccountIdentity() }; entered.await(); reading.cancelAndJoin(); block = false
        assertEquals(identity, session.localAccountIdentity())
        backing.value = "invalid journal"
        assertFails { session.localAccountIdentity() }
        assertEquals(requests, api.requests.size)
    }

    @Test fun `all HTTP response shapes reject same device replacement and old activations stay retired`() = runTest {
        val actions: List<suspend (AuthenticatedTransport) -> Unit> = listOf(
            { it.request("/read") }, { it.requestWithQuery("/read", emptyMap(), 1024) },
            { it.requestWithResourcePlans("/plans") }, { it.requestWithoutReplay("/write", buildJsonObject {}) },
            { it.putWithoutReplay("/write", buildJsonObject {}) }, { it.requestArray("/batch", buildJsonObject {}) },
            { it.mediaTarget("/media", emptyMap(), 1024) })
        for (action in actions) {
            val store = MemorySecrets(); val fake = FakeAccount(); val auth = AuthSession(store, fake) { 0 }
            val credentials = auth.login("account", "password123456"); val record = store.value
            var sent = 0
            val edge = object : EdgeTransport {
                suspend fun response(): EdgeResponse {
                    sent++; auth.logout(); store.value = record
                    return EdgeResponse(200, buildJsonObject {})
                }
                override suspend fun request(path: String, credentials: Credentials, payload: JsonObject?, query: Pair<String, String>?, maximumBytes: Long) = response()
                override suspend fun put(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long) = response()
                override suspend fun requestArray(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long) = response()
                override suspend fun requestWithQuery(path: String, credentials: Credentials, query: Map<String, String>, maximumBytes: Long) = response()
            }
            val owner = AccountNetworkActivity(); val client = owner.authenticated(auth, edge, credentials.userId, credentials.deviceId)
            assertFailsWith<ClientFailure.SessionInvalidated> { action(client) }
            assertEquals(1, sent)
            assertFailsWith<ClientFailure.SessionInvalidated> { action(client) }
            assertFailsWith<ClientFailure.SessionInvalidated> { owner.access(auth) }
            assertEquals(1, sent); owner.closeAndDrain()
        }
    }

    @Test fun `401 from an old lifetime cannot refresh or replay under its replacement`() = runTest {
        val store = MemorySecrets(); val fake = FakeAccount(); val auth = AuthSession(store, fake) { 0 }
        val credentials = auth.login("account", "password123456"); val record = store.value; var sent = 0
        val edge = object : EdgeTransport {
            override suspend fun request(path: String, credentials: Credentials, payload: JsonObject?, query: Pair<String, String>?, maximumBytes: Long): EdgeResponse {
                sent++; auth.logout(); store.value = record; return EdgeResponse(401, buildJsonObject {})
            }
        }
        val client = AuthenticatedApi(auth, edge, credentials.userId, credentials.deviceId)
        assertFailsWith<ClientFailure.SessionInvalidated> { client.request("/read") }
        assertEquals(1, sent); assertEquals(0, fake.requests.count { it.first.endsWith("refresh") })
    }
}
