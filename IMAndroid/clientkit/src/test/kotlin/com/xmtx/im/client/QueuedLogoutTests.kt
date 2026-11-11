package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

class QueuedLogoutTests {
    private class Marker : LocalExitMarker {
        var pending = false; var failClear = false
        override suspend fun isPending() = pending
        override suspend fun markPending() { pending = true }
        override suspend fun clearPending() { if (failClear) throw IOException(); pending = false }
    }
    private class Fixture {
        val disk = MemorySecrets(); val queueDisk = MemorySecrets(); val marker = Marker(); val api = FakeAccount()
        var failDelete = false; var dropDelete = false; var dropWrite = false
        val secrets = object : SecretStore by disk {
            override suspend fun write(value: String) { if (!dropWrite) disk.write(value) }
            override suspend fun delete() { if (failDelete) throw IOException(); if (!dropDelete) disk.delete() }
        }
        val queue = CredentialRevocationQueue(queueDisk)
        val receipts = IssuedCredentialRecoveryStore(MemorySecrets(), queue)
        val registrations = DeviceRegistrationStore(MemorySecrets()) { 0 }
        fun auth() = AuthSession(secrets, api, marker, receipts, registrations) { 0 }
        fun operation() = Json.parseToJsonElement(disk.value!!).jsonObject.string("revocationOperation")
    }
    @Test fun offlineLogoutPersistsIdentityBeforeHandoffAndDeletesOnlyAfterTheLocalDrain() = runTest {
        val f = Fixture(); val auth = f.auth(); val credentials = auth.login("account", "password123456")
        f.api.requests.clear(); f.api.failure = IOException()
        var operation: String? = null
        auth.logout { scope ->
            assertEquals(LocalExitAccount(credentials.userId, credentials.deviceId), scope)
            assertTrue(f.marker.pending); assertNotNull(f.disk.value); assertTrue(f.queue.jobs().isEmpty())
            operation = f.operation()
        }
        assertNull(f.disk.value); assertFalse(f.marker.pending); assertFalse(auth.hasCleanup()); assertTrue(f.api.requests.isEmpty())
        assertEquals(CredentialRevocationIntent.received(credentials, requireNotNull(operation)), f.queue.jobs().single().intent)
        assertFalse(f.queueDisk.value!!.contains(credentials.accessToken)); assertFalse(f.queueDisk.value!!.contains(credentials.refreshCredential))
    }
    @Test fun failedQueueCommitRetainsCredentialAndStableOperationAcrossOwners() = runTest {
        val f = Fixture(); val auth = f.auth(); val c = auth.login("account", "password123456"); f.api.requests.clear()
        f.queueDisk.failWrite = true
        assertFailsWith<CredentialRecoveryFailure> { auth.logout() }; val operation = f.operation()
        assertTrue(f.marker.pending); assertNotNull(f.disk.value); assertTrue(f.queue.jobs().isEmpty())
        assertFails { f.auth().login("other", "password123456") }
        f.queueDisk.failWrite = false; f.auth().logout()
        assertEquals(CredentialRevocationIntent.received(c, operation), f.queue.jobs().single().intent)
        assertNull(f.disk.value); assertFalse(f.marker.pending); assertTrue(f.api.requests.isEmpty())
    }
    @Test fun failedCredentialDeletePreservesPausedQueueIdentityAndRetryDoesNotSendDirectly() = runTest {
        val f = Fixture(); val auth = f.auth(); auth.login("account", "password123456"); f.failDelete = true
        assertFailsWith<IOException> { auth.logout() }; val original = f.queue.jobs().single()
        f.queue.recordFailure(original, 100, CredentialRevocationJob.Pause.OperationConflict); val paused = f.queue.jobs().single()
        f.api.requests.clear(); f.failDelete = false; f.auth().logout()
        assertEquals(paused, f.queue.jobs().single()); assertTrue(f.api.requests.isEmpty()); assertNull(f.disk.value)
    }
    @Test fun completedJobBeforeFailedDeletionRequeuesTheSameOperationOnColdRetry() = runTest {
        val f = Fixture(); val auth = f.auth(); auth.login("account", "password123456"); f.failDelete = true
        assertFailsWith<IOException> { auth.logout() }; val original = f.queue.jobs().single(); f.queue.complete(original)
        f.failDelete = false; f.auth().logout(); assertEquals(original.intent, f.queue.jobs().single().intent)
        assertFalse(f.marker.pending); assertNull(f.disk.value)
    }
    @Test fun existingReceiptAuthorityKeepsItsOriginalOperationAndConflictNeverDeletesCredentials() = runTest {
        for (conflicting in listOf(false, true)) {
            val f = Fixture(); val auth = f.auth(); val c = auth.login("account", "password123456")
            val authority = CredentialRevocationIntent.received(c, UUID.randomUUID().toString().uppercase())
                .let { if (conflicting) it.copy(expiresAt = it.expiresAt + 1) else it }
            f.queue.enqueue(authority); val original = f.queue.jobs().single()
            if (conflicting) {
                assertEquals(CredentialRecoveryFailure.Reason.Conflict, assertFailsWith<CredentialRecoveryFailure> { auth.logout() }.reason)
                assertTrue(f.marker.pending); assertNotNull(f.disk.value)
            } else { auth.logout(); assertNull(f.disk.value); assertFalse(f.marker.pending) }
            assertEquals(original, f.queue.jobs().single())
        }
    }
    @Test fun cancellationDuringQueueCommitFinishesItsReadbackButDoesNotReleaseTheExitGate() = runTest {
        val backing = MemorySecrets(); val queueBacking = MemorySecrets(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val marker = Marker(); val api = FakeAccount()
        val queue = CredentialRevocationQueue(object : SecretStore by queueBacking {
            override suspend fun write(value: String) { entered.complete(Unit); release.await(); queueBacking.write(value) }
        })
        val receipts = IssuedCredentialRecoveryStore(MemorySecrets(), queue)
        val auth = AuthSession(backing, api, marker, receipts) { 0 }; auth.login("account", "password123456")
        val task = launch { auth.logout() }; entered.await(); task.cancel(); assertFalse(task.isCompleted)
        release.complete(Unit); task.join(); assertTrue(marker.pending); assertEquals(1, queue.jobs().size)
        AuthSession(backing, api, marker, receipts) { 0 }.logout(); assertNull(backing.value); assertFalse(marker.pending)
    }
    @Test fun silentQueueWriteLossAndDroppedCredentialDeletionCannotClaimLocalCompletion() = runTest {
        val f = Fixture(); val c = f.auth().login("account", "password123456")
        val brokenQueue = CredentialRevocationQueue(object : SecretStore {
            override suspend fun read(): String? = null
            override suspend fun write(value: String) {}
            override suspend fun delete() {}
        })
        val auth = AuthSession(f.secrets, f.api, f.marker, IssuedCredentialRecoveryStore(MemorySecrets(), brokenQueue)) { 0 }
        assertFailsWith<CredentialRecoveryFailure> { auth.logout() }; assertNotNull(f.disk.value); assertTrue(f.marker.pending)
        f.dropDelete = true; assertFailsWith<ClientFailure.Storage> { f.auth().logout() }
        assertEquals(c.deviceId, f.queue.jobs().single().intent.device); assertTrue(f.marker.pending)
        f.dropDelete = false; f.auth().logout(); assertNull(f.disk.value); assertFalse(f.marker.pending)
    }
    @Test fun failedMarkerClearDoesNotRequireReenqueuingOrReadingDeletedCredentials() = runTest {
        val f = Fixture(); val auth = f.auth(); auth.login("account", "password123456"); f.marker.failClear = true
        assertFailsWith<IOException> { auth.logout() }; assertNull(f.disk.value); val original = f.queue.jobs().single()
        f.marker.failClear = false; f.auth().logout(); assertFalse(f.marker.pending); assertEquals(original, f.queue.jobs().single())
    }
    @Test fun silentlyDroppedOperationWriteCannotHandOffOrDeleteTheOriginalCredentials() = runTest {
        val f = Fixture(); val auth = f.auth(); auth.login("account", "password123456"); val original = f.disk.value
        f.api.requests.clear(); f.dropWrite = true
        assertEquals(CredentialStoreFailure.Reason.Unavailable, assertFailsWith<CredentialStoreFailure> { auth.logout() }.reason)
        assertEquals(original, f.disk.value); assertTrue(f.queue.jobs().isEmpty()); assertTrue(f.api.requests.isEmpty()); assertTrue(f.marker.pending)
        f.dropWrite = false; f.auth().logout(); assertNull(f.disk.value); assertFalse(f.marker.pending); assertEquals(1, f.queue.jobs().size)
    }
    @Test fun awaitingIssuanceReceiptAlsoWaitsForNativeDrainBeforeItCanBeRevoked() = runTest {
        val f = Fixture(); val auth = f.auth(); val c = auth.login("account", "password123456")
        val receipt = f.receipts.receive(c, UUID.randomUUID().toString().uppercase())
        auth.logout {
            assertTrue(f.marker.pending); assertNotNull(f.operation())
            assertTrue(f.receipts.hasPendingReceipts()); assertTrue(f.queue.jobs().isEmpty())
        }
        assertNull(f.disk.value); assertFalse(f.marker.pending); assertFalse(f.receipts.hasPendingReceipts())
        assertEquals(receipt, f.queue.jobs().single().intent)
    }
}
