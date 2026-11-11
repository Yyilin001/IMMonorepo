package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class LocalExitTests {
    private class Marker : LocalExitMarker {
        var pending = false
        var failRead = false; var failMark = false; var failClear = false
        override suspend fun isPending(): Boolean { if (failRead) throw LocalExitFailure(LocalExitFailure.Reason.Unavailable); return pending }
        override suspend fun markPending() { if (failMark) throw IOException(); pending = true }
        override suspend fun clearPending() { if (failClear) throw IOException(); pending = false }
    }
    @Test fun `committed exit blocks reopened owners even when credential intent could not be saved`() = runTest {
        val secrets = MemorySecrets(); val api = FakeAccount(); val marker = Marker()
        val auth = AuthSession(secrets, api, marker) { 0 }; auth.login("account", "password123456")
        val original = secrets.value; val requests = api.requests.size; secrets.failWrite = true
        assertFailsWith<IOException> { auth.logout() }
        assertTrue(marker.pending); assertEquals(original, secrets.value); assertEquals(requests, api.requests.size)
        val reopened = AuthSession(secrets, api, marker) { 0 }
        assertTrue(reopened.hasCleanup()); assertNull(reopened.current())
        assertFailsWith<ClientFailure.SignedOut> { reopened.localAccountIdentity() }
        assertFailsWith<ClientFailure.SignedOut> { reopened.access() }
        assertFails { reopened.login("account", "password123456") }
        secrets.failWrite = false; reopened.logout()
        assertNull(secrets.value); assertFalse(marker.pending); assertFalse(reopened.hasCleanup())
    }
    @Test fun `marker failure stops credential mutation and network cleanup`() = runTest {
        val secrets = MemorySecrets(); val api = FakeAccount(); val marker = Marker()
        val auth = AuthSession(secrets, api, marker) { 0 }; auth.login("account", "password123456")
        val original = secrets.value; val requests = api.requests.size; marker.failMark = true
        assertFailsWith<IOException> { auth.logout() }
        assertEquals(original, secrets.value); assertEquals(requests, api.requests.size)
        assertTrue(auth.hasCleanup()); assertNull(auth.current())
        marker.failMark = false; auth.logout(); assertFalse(marker.pending)
    }
    @Test fun `unreadable marker prevents credentials from being read or used`() = runTest {
        val marker = Marker().apply { failRead = true }
        val secrets = object : SecretStore {
            override suspend fun read(): String? = error("credentials read before exit marker")
            override suspend fun write(value: String) = error("credentials changed")
            override suspend fun delete() = error("credentials deleted")
        }
        val api = FakeAccount(); val auth = AuthSession(secrets, api, marker)
        assertFailsWith<LocalExitFailure> { auth.hasCleanup() }
        assertFailsWith<LocalExitFailure> { auth.current() }
        assertFailsWith<LocalExitFailure> { auth.localAccountIdentity() }
        assertFailsWith<LocalExitFailure> { auth.access() }
        assertFailsWith<LocalExitFailure> { auth.login("account", "password123456") }
        assertTrue(api.requests.isEmpty())
    }
    @Test fun `silent credential deletion failure cannot clear the independent exit marker`() = runTest {
        val backing = MemorySecrets(); val marker = Marker(); val api = FakeAccount()
        val secrets = object : SecretStore by backing { override suspend fun delete() {} }
        val auth = AuthSession(secrets, api, marker) { 0 }; auth.login("account", "password123456")
        assertFailsWith<ClientFailure.Storage> { auth.logout() }
        assertNotNull(backing.value); assertTrue(marker.pending)
        assertTrue(AuthSession(backing, api, marker).hasCleanup())
        AuthSession(backing, api, marker).logout(); assertNull(backing.value); assertFalse(marker.pending)
    }
    @Test fun `clear failure retains pending state after credentials are already deleted`() = runTest {
        val secrets = MemorySecrets(); val api = FakeAccount(); val marker = Marker()
        val auth = AuthSession(secrets, api, marker) { 0 }; auth.login("account", "password123456")
        marker.failClear = true; assertFailsWith<IOException> { auth.logout() }
        assertNull(secrets.value); assertTrue(marker.pending)
        val requests = api.requests.size; val reopened = AuthSession(secrets, api, marker)
        assertTrue(reopened.hasCleanup()); marker.failClear = false; reopened.logout()
        assertFalse(marker.pending); assertEquals(requests, api.requests.size)
    }
    @Test fun `prepared exit survives owner loss before draining or credential deletion`() = runTest {
        val secrets = MemorySecrets(); val api = FakeAccount(); val marker = Marker()
        val auth = AuthSession(secrets, api, marker) { 0 }; auth.login("account", "password123456")
        val record = secrets.value; val requests = api.requests.size; val identity = auth.localAccountIdentity()
        auth.prepareLocalExit()
        assertEquals(record, secrets.value); assertEquals(requests, api.requests.size)
        assertFailsWith<ClientFailure.SessionInvalidated> { auth.requireLocalIdentity(identity) }
        assertTrue(AuthSession(secrets, api, marker).hasCleanup())
        AuthSession(secrets, api, marker).logout(); assertFalse(marker.pending)
    }
    @Test fun `cancellation after marker commit keeps the old credentials blocked on reopening`() = runTest {
        val backing = MemorySecrets(); val marker = Marker(); val api = FakeAccount()
        var block = false; val entered = CompletableDeferred<Unit>()
        val secret = object : SecretStore by backing {
            override suspend fun write(value: String) {
                if (block) { entered.complete(Unit); awaitCancellation() }
                backing.write(value)
            }
        }
        val auth = AuthSession(secret, api, marker) { 0 }; auth.login("account", "password123456")
        val original = backing.value; val requests = api.requests.size; block = true
        val logout = launch { auth.logout() }; entered.await(); assertTrue(marker.pending)
        logout.cancelAndJoin()
        assertEquals(original, backing.value); assertEquals(requests, api.requests.size)
        val reopened = AuthSession(secret, api, marker)
        assertNull(reopened.current()); assertTrue(reopened.hasCleanup())
        block = false; reopened.logout(); assertFalse(marker.pending)
    }
    @Test fun `native cleanup failure retains credential scope before any remote revocation or deletion`() = runTest {
        val secrets = MemorySecrets(); val marker = Marker(); val api = FakeAccount()
        val auth = AuthSession(secrets, api, marker) { 0 }; val credentials = auth.login("account", "password123456")
        val account = LocalExitAccount(credentials.userId, credentials.deviceId); val requests = api.requests.size
        assertFailsWith<IOException> { auth.logout { scope -> assertEquals(account, scope); assertTrue(marker.pending); throw IOException() } }
        assertTrue(marker.pending); assertNotNull(secrets.value); assertEquals(requests, api.requests.size)
        val reopened = AuthSession(secrets, api, marker)
        val before = secrets.value
        reopened.drainLocalExitWork { assertEquals(account, it); assertTrue(marker.pending) }
        assertEquals(before, secrets.value); assertEquals(requests, api.requests.size); assertNull(reopened.current())
        reopened.logout { assertEquals(account, it); assertNotNull(secrets.value) }
        assertNull(secrets.value); assertFalse(marker.pending)
    }
    @Test fun `cancelled cleanup is retried with the same identity and empty credentials still run cleanup`() = runTest {
        val secrets = MemorySecrets(); val marker = Marker(); val api = FakeAccount()
        val auth = AuthSession(secrets, api, marker) { 0 }; val credentials = auth.login("account", "password123456")
        val entered = CompletableDeferred<Unit>(); val requests = api.requests.size
        val task = launch { auth.logout { assertEquals(LocalExitAccount(credentials.userId, credentials.deviceId), it); entered.complete(Unit); awaitCancellation() } }
        entered.await(); task.cancelAndJoin()
        assertTrue(marker.pending); assertNotNull(secrets.value); assertEquals(requests, api.requests.size)
        val reopened = AuthSession(secrets, api, marker); reopened.logout { assertEquals(credentials.userId, it?.user) }
        marker.pending = true; var called = false
        AuthSession(secrets, api, marker).logout { assertNull(it); called = true }
        assertTrue(called); assertFalse(marker.pending)
    }
}
