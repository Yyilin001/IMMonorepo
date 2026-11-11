package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class SharedRefreshTests {
    private class Server : AccountTransport {
        val fake = FakeAccount().apply { accessExpiry = 1 }
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val drained = CompletableDeferred<Unit>()
        var refreshes = 0
        var reject = false
        var beforeDrain: suspend () -> Unit = {}
        override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
            if (!path.endsWith("refresh")) return fake.post(path, payload, accessToken, expectedStatus)
            refreshes++; entered.complete(Unit)
            try {
                release.await()
                if (reject) throw ClientFailure.Http(401)
                return fake.post(path, payload, accessToken, expectedStatus)
            } finally { withContext(NonCancellable) { beforeDrain(); drained.complete(Unit) } }
        }
    }
    private class Marker : LocalExitMarker {
        var pending = false
        var fail = false
        override suspend fun isPending() = pending
        override suspend fun markPending() { if (fail) throw IOException(); pending = true }
        override suspend fun clearPending() { pending = false }
    }
    private fun operation(store: MemorySecrets) = Json.parseToJsonElement(store.value!!).jsonObject["refreshOperation"]
    private fun replace(store: MemorySecrets, field: String, value: String) {
        val journal = Json.parseToJsonElement(store.value!!).jsonObject
        val credentials = journal.getValue("credentials").jsonObject
        store.value = JsonObject(journal + ("credentials" to JsonObject(credentials + (field to JsonPrimitive(value))))).toString()
    }

    @Test fun cancellingInitiatorDoesNotCancelOtherWaitersOrTheSuccessorCommit() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456"); val epoch = auth.currentEpoch()
        val first = async { auth.access() }; server.entered.await()
        val rest = List(12) { async { auth.access() } }; runCurrent()
        assertEquals(AuthSessionState.Refreshing, auth.currentState())
        first.cancelAndJoin(); assertFalse(server.drained.isCompleted)
        // A short-lived successor must still be shared by callers that joined the pending refresh.
        server.fake.accessExpiry = 2; server.release.complete(Unit)
        val results = rest.awaitAll(); assertTrue(results.all { it == results.first() })
        assertEquals(2, results.first().accessExpiresAt); assertEquals(1, server.refreshes)
        assertEquals(results.first(), auth.current()); assertNull(operation(store)); assertSame(epoch, auth.currentEpoch())
    }

    @Test fun ownerCancellationBeforeDispatchDoesNotLeaveAnUnretryableFlight() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456")
        val waiting = async(start = CoroutineStart.UNDISPATCHED) { auth.access() }
        val id = operation(store); assertFalse(server.entered.isCompleted)
        auth.cancelRefreshAndDrain()
        assertFailsWith<CancellationException> { waiting.await() }
        assertEquals(AuthSessionState.Authenticated(1), auth.currentState())
        assertFalse(server.entered.isCompleted); assertEquals(id, operation(store))
        server.fake.accessExpiry = 200_000; server.release.complete(Unit)
        assertEquals(200_000, auth.access().accessExpiresAt)
        assertEquals(id, server.fake.requests.last().second["operationID"]); assertEquals(1, server.refreshes)
    }

    @Test fun noWaitersStillCommitsAndFailureRetryReusesThePersistedIdentity() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456")
        val waiting = async { auth.access() }; server.entered.await(); val id = operation(store)
        waiting.cancelAndJoin(); store.failWrite = true; server.release.complete(Unit); runCurrent()
        assertEquals(id, operation(store)); assertEquals(1, auth.current()!!.accessExpiresAt)
        store.failWrite = false; server.fake.accessExpiry = 200_000; auth.access()
        assertEquals(id, server.fake.requests.last().second["operationID"]); assertNull(operation(store))
        assertEquals(2, server.refreshes)
    }

    @Test fun successfulRefreshPersistsAfterEveryWaiterHasCancelled() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456")
        val first = async { auth.access() }; server.entered.await()
        val second = async { auth.access() }; runCurrent()
        first.cancelAndJoin(); second.cancelAndJoin(); assertFalse(server.drained.isCompleted)
        server.fake.accessExpiry = 300_000; server.release.complete(Unit); runCurrent()
        assertEquals(300_000, auth.current()!!.accessExpiresAt); assertNull(operation(store)); assertEquals(1, server.refreshes)
    }

    @Test fun exitCommitsIntentBeforeWaitingForTheCancelledOwnerToDrain() = runTest {
        val store = MemorySecrets(); val server = Server(); val marker = Marker(); val auth = AuthSession(store, server, marker) { 0 }
        auth.login("account", "password123456")
        val waiting = async { auth.access() }; server.entered.await()
        val cleanupGate = CompletableDeferred<Unit>(); server.beforeDrain = { cleanupGate.await() }
        val exit = async { auth.prepareLocalExit() }; runCurrent()
        assertTrue(marker.pending); assertFalse(exit.isCompleted); assertNull(auth.current())
        cleanupGate.complete(Unit); exit.await(); assertTrue(server.drained.isCompleted)
        assertFailsWith<CancellationException> { waiting.await() }
        assertEquals(1, Json.parseToJsonElement(store.value!!).jsonObject.getValue("credentials").jsonObject.getValue("accessExpiresAt").jsonPrimitive.long)
        auth.logout(); assertNull(store.value); assertFalse(marker.pending)
        assertEquals(1, server.fake.requests.count { it.first.endsWith("revoke") })
    }

    @Test fun markerWriteFailureStillDrainsRefreshWithoutDeletingCredentials() = runTest {
        val store = MemorySecrets(); val server = Server(); val marker = Marker(); val auth = AuthSession(store, server, marker) { 0 }
        auth.login("account", "password123456")
        val waiting = async { auth.access() }; server.entered.await(); val before = store.value
        marker.fail = true; assertFailsWith<IOException> { auth.prepareLocalExit() }
        assertTrue(server.drained.isCompleted); assertEquals(before, store.value); assertTrue(auth.hasCleanup())
        assertFailsWith<CancellationException> { waiting.await() }
    }

    @Test fun overlappingLogoutCannotRetireAnAccountCreatedWhileItWasDraining() = runTest {
        val store = MemorySecrets(); val server = Server(); val marker = Marker(); val auth = AuthSession(store, server, marker) { 0 }
        auth.login("account", "password123456")
        val waiting = async { auth.access() }; server.entered.await()
        val gate = CompletableDeferred<Unit>(); server.beforeDrain = { gate.await() }
        val first = async(UnconfinedTestDispatcher(testScheduler)) {
            auth.logout(); auth.login("replacement", "password123456")
        }
        val second = async { runCatching { auth.logout() } }; runCurrent()
        assertFalse(first.isCompleted); assertFalse(second.isCompleted)
        gate.complete(Unit); val replacement = first.await()
        assertIs<ClientFailure.SessionInvalidated>(second.await().exceptionOrNull())
        assertEquals(replacement, auth.current()); assertFalse(marker.pending)
        assertEquals(1, server.fake.requests.count { it.first.endsWith("revoke") })
        assertFailsWith<CancellationException> { waiting.await() }
    }

    @Test fun lateSuccessCannotOverwriteReplacedCredentialsOfTheSameAccount() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456")
        val waiting = async { runCatching { auth.access() } }; server.entered.await()
        replace(store, "refreshCredential", "replacement-refresh"); val before = store.value
        server.release.complete(Unit)
        assertIs<ClientFailure.SessionInvalidated>(waiting.await().exceptionOrNull())
        assertEquals(before, store.value); assertFalse(auth.hasCleanup())
    }

    @Test fun lateUnauthorizedResponseCannotMarkAReplacementAccountForExit() = runTest {
        val store = MemorySecrets(); val server = Server(); val marker = Marker(); val auth = AuthSession(store, server, marker) { 0 }
        auth.login("account", "password123456"); val epoch = auth.currentEpoch()
        val waiting = async { runCatching { auth.access() } }; server.entered.await()
        replace(store, "userId", "replacement-user"); val before = store.value
        server.reject = true; server.release.complete(Unit)
        assertIs<ClientFailure.SessionInvalidated>(waiting.await().exceptionOrNull())
        assertNotSame(epoch, auth.currentEpoch()); assertEquals(before, store.value)
        assertFalse(marker.pending); assertFalse(auth.hasCleanup())
    }

    @Test fun oldEpochCanDrainItsFlightWithoutCancellingTheReplacementFlight() = runTest {
        val store = MemorySecrets(); val server = Server(); val auth = AuthSession(store, server) { 0 }
        auth.login("account", "password123456"); val oldEpoch = auth.currentEpoch()
        val old = async { auth.access() }; server.entered.await()
        replace(store, "userId", "replacement-user"); auth.current()
        val replacement = async { runCatching { auth.access() } }; runCurrent()
        assertEquals(2, server.refreshes)
        auth.cancelRefreshAndDrain(oldEpoch); assertTrue(old.isCancelled); assertFalse(replacement.isCompleted)
        auth.cancelRefreshAndDrain(auth.currentEpoch()); replacement.await()
    }

    @Test fun sharedOperationRetainsOwnerContextAndDrainsBeyondCancelledWaiters() = runTest {
        val entered = CompletableDeferred<Unit>(); val gate = CompletableDeferred<Unit>(); val draining = CompletableDeferred<Unit>()
        val inherited = CoroutineName("shared-owner")
        val operation = SharedOperation(currentCoroutineContext() + inherited) {
            assertEquals(inherited, currentCoroutineContext()[CoroutineName]); entered.complete(Unit)
            try { awaitCancellation() } finally { withContext(NonCancellable) { draining.complete(Unit); gate.await() } }
        }
        val waiter = async { operation.await() }; entered.await(); waiter.cancelAndJoin()
        assertFalse(draining.isCompleted)
        val retired = async { operation.cancelAndDrain() }; draining.await(); assertFalse(retired.isCompleted)
        gate.complete(Unit); retired.await(); assertIs<CancellationException>(operation.result().exceptionOrNull())
    }
}
