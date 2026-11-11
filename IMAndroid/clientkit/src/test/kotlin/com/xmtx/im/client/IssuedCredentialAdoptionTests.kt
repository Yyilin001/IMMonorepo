package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

class IssuedCredentialAdoptionTests {
    private class Marker : LocalExitMarker {
        var pending = false
        override suspend fun isPending() = pending
        override suspend fun markPending() { pending = true }
        override suspend fun clearPending() { pending = false }
    }
    private class Fixture {
        val backing = MemorySecrets(); val receiptsDisk = MemorySecrets(); val queueDisk = MemorySecrets()
        val queue = CredentialRevocationQueue(queueDisk); val receipts = IssuedCredentialRecoveryStore(receiptsDisk, queue)
        val marker = Marker(); val fake = FakeAccount()
        var afterIssue: suspend (JsonObject) -> JsonObject = { it }
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                val response = fake.post(path, payload, accessToken, expectedStatus)
                return if (path == "/v2/device-credentials") afterIssue(response) else response
            }
        }
        fun auth(store: SecretStore = backing) = AuthSession(store, api, marker, receipts) { 0 }
    }
    private fun hasCredentials(value: String) = Json.parseToJsonElement(value).jsonObject["credentials"] != null
    private fun replacement() = Credentials(UserId("replacement"), DeviceId(UUID.randomUUID().toString()), "replacement-access", 100000,
        "replacement-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 1000000)

    @Test fun receivedAuthorityIsJournaledBeforeTheAuthCommitAndConfirmedOnlyAfterReadback() = runTest {
        val f = Fixture(); var checked = false
        val store = object : SecretStore by f.backing {
            override suspend fun write(value: String) {
                if (hasCredentials(value)) { assertTrue(f.receipts.hasPendingReceipts()); assertTrue(f.queue.jobs().isEmpty()); checked = true }
                f.backing.write(value)
            }
        }
        val auth = f.auth(store); val c = auth.login("account", "password123456")
        assertTrue(checked); assertEquals(c, auth.current()); assertFalse(f.receipts.hasPendingReceipts()); assertFalse(f.marker.pending)
        assertTrue(f.queue.jobs().isEmpty())
    }
    @Test fun cancellationAfterAResponseButBeforeAdoptionPersistsCleanupAndQueuesRevocation() = runTest {
        val f = Fixture(); f.afterIssue = { currentCoroutineContext().cancel(); it }
        val auth = f.auth(); val login = async { auth.login("account", "password123456") }
        assertFailsWith<CancellationException> { login.await() }
        assertTrue(f.marker.pending); assertTrue(auth.hasCleanup()); assertNull(auth.current())
        assertFalse(f.receipts.hasPendingReceipts()); assertEquals(1, f.queue.jobs().size)
        val pending = Json.parseToJsonElement(f.backing.value!!).jsonObject.getValue("registration").jsonObject
        assertEquals(pending.string("operation"), f.queue.jobs().single().intent.operation)
        assertFailsWith<IllegalStateException> { f.auth().login("account", "password123456") }
    }
    @Test fun cancellationAfterTheDurableAuthWriteAdoptsInsteadOfRevokingTheOwnedSession() = runTest {
        val f = Fixture()
        val store = object : SecretStore by f.backing {
            override suspend fun write(value: String) { f.backing.write(value); if (hasCredentials(value)) currentCoroutineContext().cancel() }
        }
        val login = async { f.auth(store).login("account", "password123456") }
        assertFailsWith<CancellationException> { login.await() }
        assertFalse(f.receipts.hasPendingReceipts()); assertTrue(f.queue.jobs().isEmpty()); assertFalse(f.marker.pending)
        assertNotNull(f.auth().current())
    }
    @Test fun failedAuthCommitRetainsReceiptThenColdRecoveryBlocksReplayOfTheAbandonedRegistration() = runTest {
        val f = Fixture()
        val store = object : SecretStore by f.backing { override suspend fun write(value: String) {
            if (hasCredentials(value)) throw IOException(); f.backing.write(value)
        } }
        assertFailsWith<IOException> { f.auth(store).login("account", "password123456") }
        assertTrue(f.receipts.hasPendingReceipts()); assertFalse(f.marker.pending)
        val pending = f.backing.value; val restored = f.auth(); restored.recoverIssuedCredentials()
        assertTrue(restored.hasCleanup()); assertNull(restored.current()); assertTrue(f.marker.pending)
        assertEquals(1, f.queue.jobs().size); assertFalse(f.receipts.hasPendingReceipts())
        assertTrue(f.backing.value!!.contains("registration")); assertNotEquals(pending, f.backing.value)
        val before = f.fake.requests.size
        assertFailsWith<IllegalStateException> { restored.login("account", "password123456") }; assertEquals(before, f.fake.requests.size)
        restored.logout(); assertNull(f.backing.value); assertFalse(f.marker.pending)
        assertEquals(1, f.fake.requests.count { it.first.endsWith("cancel-registration") })
        assertEquals(0, f.fake.requests.count { it.first.endsWith("revoke") }); assertEquals(1, f.queue.jobs().size)
    }
    @Test fun uncertainWriteThatActuallyCommittedIsRecoveredAsOwned() = runTest {
        val f = Fixture()
        val store = object : SecretStore by f.backing { override suspend fun write(value: String) {
            f.backing.write(value); if (hasCredentials(value)) throw IOException()
        } }
        assertFailsWith<IOException> { f.auth(store).login("account", "password123456") }
        assertTrue(f.receipts.hasPendingReceipts()); val before = f.backing.value
        f.auth().recoverIssuedCredentials(); assertEquals(before, f.backing.value)
        assertFalse(f.receipts.hasPendingReceipts()); assertTrue(f.queue.jobs().isEmpty()); assertFalse(f.marker.pending)
    }
    @Test fun silentlyDroppedAuthWriteNeverConfirmsTheRecoveryReceipt() = runTest {
        val f = Fixture()
        val store = object : SecretStore by f.backing { override suspend fun write(value: String) {
            if (!hasCredentials(value)) f.backing.write(value)
        } }
        val auth = f.auth(store)
        assertFailsWith<CredentialStoreFailure> { auth.login("account", "password123456") }
        assertEquals(AuthSessionState.CredentialsUnavailable(CredentialStoreFailure.Reason.Unavailable), auth.currentState())
        assertTrue(f.receipts.hasPendingReceipts()); f.auth().recoverIssuedCredentials()
        assertTrue(f.marker.pending); assertEquals(1, f.queue.jobs().size)
    }
    @Test fun confirmationMismatchIsAbandonedWithoutPublishingAuthenticatedCredentials() = runTest {
        val f = Fixture(); f.afterIssue = { JsonObject(it - "registrationCancellation") }; val auth = f.auth()
        assertFailsWith<ClientFailure.Protocol> { auth.login("account", "password123456") }
        assertNull(auth.current()); assertTrue(f.marker.pending); assertEquals(1, f.queue.jobs().size)
        assertFalse(f.receipts.hasPendingReceipts())
    }
    @Test fun replacedSessionIsNeverMarkedForExitOrOverwrittenByLateIssuance() = runTest {
        val f = Fixture(); val replacement = replacement()
        f.afterIssue = { response -> f.backing.value = buildJsonObject { put("credentials", Json.encodeToJsonElement(replacement)) }.toString(); response }
        val auth = f.auth()
        assertFailsWith<ClientFailure.SessionInvalidated> { auth.login("account", "password123456") }
        assertEquals(replacement, auth.current()); assertFalse(f.marker.pending); assertFalse(auth.hasCleanup())
        assertEquals(1, f.queue.jobs().size); assertNotEquals(replacement.deviceId, f.queue.jobs().single().intent.device)
    }
    @Test fun unreadableAuthJournalCannotTurnAnAwaitingReceiptIntoAnAbandonedOne() = runTest {
        val f = Fixture(); f.receipts.receive(replacement(), UUID.randomUUID().toString().uppercase())
        val before = f.receiptsDisk.value
        val store = object : SecretStore by f.backing { override suspend fun read(): String? = throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable) }
        assertFailsWith<CredentialStoreFailure> { f.auth(store).recoverIssuedCredentials() }
        assertEquals(before, f.receiptsDisk.value); assertTrue(f.queue.jobs().isEmpty()); assertFalse(f.marker.pending)
    }
    @Test fun receiptConfirmationFailureAfterAuthCommitIsResolvedByColdOwnership() = runTest {
        val f = Fixture(); var failDelete = true
        val disk = object : SecretStore by f.receiptsDisk { override suspend fun delete() { if (failDelete) throw IOException(); f.receiptsDisk.delete() } }
        val receipts = IssuedCredentialRecoveryStore(disk, f.queue)
        val auth = AuthSession(f.backing, f.api, f.marker, receipts) { 0 }
        assertFailsWith<CredentialRecoveryFailure> { auth.login("account", "password123456") }
        val owned = auth.current(); assertNotNull(owned); assertTrue(receipts.hasPendingReceipts())
        failDelete = false; auth.recoverIssuedCredentials(); assertEquals(owned, auth.current())
        assertFalse(receipts.hasPendingReceipts()); assertTrue(f.queue.jobs().isEmpty())
    }
    @Test fun pendingExitQueuesReceivedAuthorityAndLogoutDoesNotRaceItsIndependentRevocation() = runTest {
        val f = Fixture(); val auth = f.auth(); val c = auth.login("account", "password123456")
        f.receipts.receive(c, UUID.randomUUID().toString().uppercase()); f.marker.pending = true
        auth.recoverIssuedCredentials(); assertEquals(1, f.queue.jobs().size)
        auth.logout(); assertNull(f.backing.value); assertFalse(f.marker.pending)
        assertEquals(0, f.fake.requests.count { it.first.endsWith("revoke") })
        assertEquals(1, f.queue.jobs().size)
    }
}
