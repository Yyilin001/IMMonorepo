package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

class ManagedRegistrationTests {
    private class Marker : LocalExitMarker {
        var pending = false
        override suspend fun isPending() = pending
        override suspend fun markPending() { pending = true }
        override suspend fun clearPending() { pending = false }
    }
    private class Fixture {
        val authDisk = MemorySecrets(); val registrationDisk = MemorySecrets(); val receiptDisk = MemorySecrets()
        val registrations = DeviceRegistrationStore(registrationDisk) { 0 }
        val queue = CredentialRevocationQueue(MemorySecrets()); val receipts = IssuedCredentialRecoveryStore(receiptDisk, queue)
        val marker = Marker(); val api = FakeAccount()
        fun auth(disk: SecretStore = authDisk, transport: AccountTransport = api) = AuthSession(disk, transport, marker, receipts, registrations) { 0 }
    }
    @Test fun proofPrecedesAssertionsAndSameProcessRetryReusesItWithoutDuplicateAuthJournal() = runTest {
        val f = Fixture(); val auth = f.auth(); var calls = 0; var device: DeviceId? = null
        val provider = DeviceBoundAccountAssertionProvider { current ->
            assertTrue(f.registrations.activity().awaitingRegistration); assertNull(f.authDisk.value)
            if (calls++ == 0) { device = current; throw IOException() }
            assertEquals(device, current); AccountAssertion("assertion")
        }
        assertFailsWith<IOException> { auth.registerDevice("example", provider) }
        val proof = f.registrations.pendingRegistrations().single()
        val c = auth.registerDevice("example", provider)
        assertEquals(proof.device, c.deviceId); assertEquals(proof.operation, f.api.requests.single().second.string("operationID"))
        assertFalse(f.registrations.hasWork()); assertFalse(f.receipts.hasPendingReceipts())
        assertFalse(f.authDisk.value!!.contains("registration"))
    }
    @Test fun lostResponseColdRecoveryQueuesOriginalProofWithoutBlockingAnotherLogin() = runTest {
        val f = Fixture(); val transport = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                val response = f.api.post(path, payload, accessToken, expectedStatus)
                if (path == "/v2/device-credentials") throw IOException()
                return response
            }
        }
        assertFailsWith<IOException> { f.auth(transport = transport).login("account", "password123456") }
        val original = f.registrations.pendingRegistrations().single(); val next = f.auth(); next.recoverIssuedCredentials()
        assertEquals(original, f.registrations.jobs().single().cancellation); assertFalse(f.marker.pending); assertFalse(next.hasCleanup())
        assertNotEquals(original.device, next.login("account", "password123456").deviceId)
        assertEquals(original, f.registrations.jobs().single().cancellation)
    }
    @Test fun registrationOnlyLogoutHandsOffOfflineAndFailedHandoffPreventsDeletingEvidence() = runTest {
        val f = Fixture(); f.api.failure = IOException(); val auth = f.auth()
        assertFailsWith<IOException> { auth.login("account", "password123456") }
        val original = f.registrations.pendingRegistrations().single(); val calls = f.api.requests.size
        f.registrationDisk.failWrite = true
        assertFailsWith<CredentialRecoveryFailure> { auth.logout() }; assertTrue(f.marker.pending)
        assertEquals(original, f.registrations.pendingRegistrations().single())
        f.registrationDisk.failWrite = false; auth.logout()
        assertEquals(calls, f.api.requests.size); assertNull(f.authDisk.value); assertFalse(f.marker.pending)
        assertEquals(original, f.registrations.jobs().single().cancellation)
    }
    @Test fun uncertainAuthCommitIsComparedBeforeEitherIndependentProofIsAbandoned() = runTest {
        for (committed in listOf(false, true)) {
            val f = Fixture(); val disk = object : SecretStore by f.authDisk {
                override suspend fun write(value: String) { if (committed) f.authDisk.write(value); throw IOException() }
            }
            assertFailsWith<IOException> { f.auth(disk).login("account", "password123456") }
            val original = f.registrations.pendingRegistrations().single(); assertTrue(f.receipts.hasPendingReceipts())
            val restored = f.auth(); restored.recoverIssuedCredentials()
            assertFalse(f.registrations.activity().awaitingRegistration); assertFalse(f.receipts.hasPendingReceipts()); assertFalse(f.marker.pending)
            if (committed) { assertNotNull(restored.current()); assertTrue(f.queue.jobs().isEmpty()); assertTrue(f.registrations.jobs().isEmpty()) }
            else { assertNull(restored.current()); assertEquals(original, f.registrations.jobs().single().cancellation); assertEquals(1, f.queue.jobs().size) }
        }
    }
    @Test fun retryAfterFailedAuthWriteRetiresTheAbandonedOperationBeforeIssuingAnother() = runTest {
        val f = Fixture(); var fail = true
        val disk = object : SecretStore by f.authDisk { override suspend fun write(value: String) { if (fail) throw IOException(); f.authDisk.write(value) } }
        val auth = f.auth(disk); assertFailsWith<IOException> { auth.login("account", "password123456") }
        val original = f.registrations.pendingRegistrations().single(); fail = false
        val c = auth.login("account", "password123456")
        assertNotEquals(original.device, c.deviceId); assertEquals(original, f.registrations.jobs().single().cancellation)
        assertEquals(1, f.queue.jobs().size); assertFalse(f.marker.pending)
    }
    @Test fun unreadableAuthCannotDiscardPendingRegistrationAndCorruptProofBlocksAnyIssuance() = runTest {
        val f = Fixture(); f.registrations.prepare("account"); val original = f.registrationDisk.value
        val unreadable = object : SecretStore by f.authDisk { override suspend fun read(): String? = throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable) }
        assertFailsWith<CredentialStoreFailure> { f.auth(unreadable).recoverIssuedCredentials() }; assertEquals(original, f.registrationDisk.value)
        f.registrationDisk.value = "{}"
        assertFailsWith<CredentialRecoveryFailure> { f.auth().login("account", "password123456") }; assertTrue(f.api.requests.isEmpty())
    }
    @Test fun legacyPendingRegistrationMigratesOnceAndCannotResurrectAfterCancellationCompletes() = runTest {
        val f = Fixture(); f.api.failure = IOException()
        assertFailsWith<IOException> { AuthSession(f.authDisk, f.api) { 0 }.login("account", "password123456") }
        val original = Json.parseToJsonElement(f.authDisk.value!!).jsonObject.getValue("registration").jsonObject.string("operation")
        val auth = f.auth(); auth.recoverIssuedCredentials(); assertEquals(original, f.registrations.jobs().single().cancellation.operation)
        f.registrations.complete(f.registrations.jobs().single()); auth.recoverIssuedCredentials(); assertFalse(f.registrations.hasWork())
        f.api.failure = null; auth.login("account", "password123456")
        assertNotEquals(original, f.api.requests.last().second.string("operationID"))
    }
}
