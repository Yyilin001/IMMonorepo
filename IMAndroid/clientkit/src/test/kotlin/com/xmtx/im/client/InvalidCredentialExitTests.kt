package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import java.util.UUID
import kotlin.test.*

class InvalidCredentialExitTests {
    private class Marker : LocalExitMarker {
        var pending = false; var fail = false
        override suspend fun isPending() = pending
        override suspend fun markPending() { if (fail) throw IOException(); pending = true }
        override suspend fun clearPending() { pending = false }
    }
    private class Fixture {
        val backing = MemorySecrets().apply { value = "damaged auth" }; val marker = Marker(); val api = FakeAccount()
        val receiptDisk = MemorySecrets(); val registrationDisk = MemorySecrets()
        val queue = CredentialRevocationQueue(MemorySecrets()); val receipts = IssuedCredentialRecoveryStore(receiptDisk, queue)
        val registrations = DeviceRegistrationStore(registrationDisk) { 0 }
        var error: CredentialStoreFailure.Reason? = null; var failDelete = false; var dropDelete = false
        val secrets = object : SecretStore by backing {
            override suspend fun read(): String? { if (backing.value != null) error?.let { throw CredentialStoreFailure(it) }; return backing.read() }
            override suspend fun write(value: String) = error("cannot overwrite unreadable credentials")
            override suspend fun delete() { if (failDelete) throw IOException(); if (!dropDelete) backing.delete() }
        }
        fun auth() = AuthSession(secrets, api, marker, receipts, registrations) { 0 }
        suspend fun seed() {
            registrations.prepare("account")
            receipts.receive(Credentials(UserId("user"), DeviceId(UUID.randomUUID().toString()), "access", 1,
                "refresh", "imv2-revoke-v1.${"A".repeat(43)}", 2), UUID.randomUUID().toString().uppercase())
        }
    }
    @Test fun explicitExitDrainsBeforeDeletingAndHandsOffReadableRecoveryAuthority() = runTest {
        for (reason in listOf(null, CredentialStoreFailure.Reason.PermanentlyInvalidated)) {
            val f = Fixture(); f.error = reason; f.seed(); val auth = f.auth(); var drained = false
            auth.logout { scope -> assertNull(scope); assertTrue(f.marker.pending); assertNotNull(f.backing.value); drained = true }
            assertTrue(drained); assertNull(f.backing.value); assertFalse(f.marker.pending)
            assertFalse(f.receipts.hasPendingReceipts()); assertEquals(1, f.queue.jobs().size); assertEquals(1, f.registrations.jobs().size)
            assertFalse(auth.hasCleanup()); assertTrue(f.api.requests.isEmpty()); assertEquals(AuthSessionState.Unauthenticated, auth.currentState())
        }
    }
    @Test fun temporaryFailureAndFailedMarkerNeverAuthorizeDeletionOrRecoveryHandoff() = runTest {
        val f = Fixture(); f.seed(); f.error = CredentialStoreFailure.Reason.Unavailable
        assertFailsWith<CredentialStoreFailure> { f.auth().logout { fail("drained unknown temporary state") } }
        assertNotNull(f.backing.value); assertTrue(f.receipts.hasPendingReceipts()); assertTrue(f.registrations.activity().awaitingRegistration)
        assertTrue(f.marker.pending); f.error = CredentialStoreFailure.Reason.PermanentlyInvalidated; f.marker.fail = true
        assertFailsWith<IOException> { f.auth().logout() }; assertNotNull(f.backing.value); assertTrue(f.queue.jobs().isEmpty())
    }
    @Test fun unreadableRecoveryJournalStopsDeletionEvenWhenAuthIsPermanentlyInvalid() = runTest {
        val f = Fixture(); f.seed(); f.receiptDisk.value = "{}"; f.error = CredentialStoreFailure.Reason.PermanentlyInvalidated
        assertFailsWith<CredentialRecoveryFailure> { f.auth().logout() }
        assertTrue(f.marker.pending); assertNotNull(f.backing.value); assertEquals("{}", f.receiptDisk.value)
    }
    @Test fun failedDeletionRetainsExitAndRetryUsesTheSameQueuedAuthorities() = runTest {
        val f = Fixture(); f.seed(); f.failDelete = true
        assertFailsWith<IOException> { f.auth().logout() }; assertTrue(f.marker.pending); assertNotNull(f.backing.value)
        val revocation = f.queue.jobs().single(); val cancellation = f.registrations.jobs().single()
        f.failDelete = false; f.auth().logout()
        assertNull(f.backing.value); assertFalse(f.marker.pending); assertEquals(revocation, f.queue.jobs().single()); assertEquals(cancellation, f.registrations.jobs().single())
    }
    @Test fun cancelledNativeDrainKeepsOriginalEvidenceAndColdPendingDrainCanResumeWithoutCredentials() = runTest {
        val f = Fixture(); f.seed(); val entered = CompletableDeferred<Unit>(); val auth = f.auth()
        val task = launch { auth.logout { assertNull(it); entered.complete(Unit); awaitCancellation() } }
        entered.await(); task.cancelAndJoin(); assertTrue(f.marker.pending); assertNotNull(f.backing.value); assertTrue(f.receipts.hasPendingReceipts())
        val cold = f.auth(); var called = false
        cold.drainLocalExitWork { assertNull(it); called = true }; assertTrue(called); assertNotNull(f.backing.value)
        cold.logout(); assertNull(f.backing.value); assertFalse(f.marker.pending)
    }
    @Test fun silentlyDroppedDeleteCannotClearTheExitMarker() = runTest {
        val f = Fixture(); f.dropDelete = true
        assertFailsWith<ClientFailure.Storage> { f.auth().logout() }; assertTrue(f.marker.pending); assertNotNull(f.backing.value)
        f.dropDelete = false; f.auth().logout(); assertNull(f.backing.value); assertFalse(f.marker.pending)
    }
    @Test fun retryAfterRecordDeletionDoesNotRequireSavingWithTheOldKey() = runTest {
        val f = Fixture(); f.backing.value = null; f.marker.pending = true
        f.auth().logout(); assertNull(f.backing.value); assertFalse(f.marker.pending); assertTrue(f.api.requests.isEmpty())
    }
}
