package com.xmtx.im.client

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.security.MessageDigest
import kotlin.test.*

class DeviceRegistrationStoreTests {
    @Test fun canonicalAccountReusesProofWithoutPersistingAccountAndExpiryAtomicallyQueuesIt() = runTest {
        val disk = MemorySecrets(); var now = 100L; val store = DeviceRegistrationStore(disk) { now }
        val first = store.prepare("Account"); assertEquals(first.cancellation, store.prepare("ACCOUNT").load())
        assertFalse(disk.value!!.contains("account", ignoreCase = true))
        val expected = MessageDigest.getInstance("SHA-256").digest("password-account-v1\u0000account".toByteArray()).joinToString("") { "%02x".format(it) }
        assertTrue(disk.value!!.contains(expected)); assertEquals(600100, first.cancellation.deadline)
        val other = store.prepare("other"); assertNotEquals(first.cancellation, other.cancellation)
        now = first.cancellation.deadline
        val next = store.prepare("account"); assertNotEquals(first.cancellation, next.cancellation)
        assertEquals(first.cancellation, store.jobs().single().cancellation)
        first.finish(); assertEquals(next.cancellation, next.load())
        assertFailsWith<CredentialRecoveryFailure> { first.abandon() }
        assertFailsWith<CredentialRecoveryFailure> { first.load() }
        assertEquals(next.cancellation, DeviceRegistrationStore(disk) { now }.prepare("account").load())
    }
    @Test fun failedExpiryCommitRetainsTheOriginalPendingIdentity() = runTest {
        val disk = MemorySecrets(); var now = 1L; val store = DeviceRegistrationStore(disk) { now }
        val original = store.prepare("account"); val bytes = disk.value; now = original.cancellation.deadline; disk.failWrite = true
        assertFailsWith<CredentialRecoveryFailure> { store.prepare("account") }; assertEquals(bytes, disk.value)
        disk.failWrite = false; assertEquals(original.cancellation, original.load()); assertTrue(store.jobs().isEmpty())
    }
    @Test fun coldRecoveryAdoptsOwnedDeviceAndQueuesEveryOtherPendingProof() = runTest {
        val disk = MemorySecrets(); val store = DeviceRegistrationStore(disk) { 0 }
        val owned = store.prepare("owned"); val lost = store.prepare("lost")
        val c = Credentials(UserId("user"), owned.cancellation.device, "access", 1, "refresh", "imv2-revoke-v1.${"A".repeat(43)}", 2)
        val cold = DeviceRegistrationStore(disk); cold.recoverUnclaimed(c)
        assertEquals(listOf(lost.cancellation), cold.jobs().map { it.cancellation })
        assertFalse(cold.activity().awaitingRegistration)
        cold.complete(cold.jobs().single()); assertFalse(cold.hasWork()); assertNull(disk.value)
    }
    @Test fun staleCompletionCannotEraseRetryAndReenqueuePreservesThePausedJob() = runTest {
        val store = DeviceRegistrationStore(MemorySecrets()) { 0 }; val handle = store.prepare("account"); handle.abandon()
        val stale = store.jobs().single(); store.recordFailure(stale, 50, RegistrationCancellationJob.Pause.InvalidResponse)
        val paused = store.jobs().single(); store.enqueueCancellation(handle.cancellation); assertEquals(paused, store.jobs().single())
        store.complete(stale); store.recordFailure(stale, 99, null); assertEquals(paused, store.jobs().single())
        store.retryPaused(); assertEquals(1, store.jobs().single().attempts); assertNull(store.jobs().single().pause)
        assertEquals(handle.cancellation, store.due(0).single().cancellation)
        assertFailsWith<CredentialRecoveryFailure> { store.enqueueCancellation(handle.cancellation.copy(deadline = 12)) }
    }
    @Test fun strictSchemaAndCapacityPreserveEvidence() = runTest {
        for (raw in listOf("{}", "{\"version\":1,\"pending\":{}}", "{\"version\":2,\"pending\":{},\"abandoned\":{}}")) {
            val disk = MemorySecrets().apply { value = raw }
            assertEquals(CredentialRecoveryFailure.Reason.Malformed, assertFailsWith<CredentialRecoveryFailure> { DeviceRegistrationStore(disk).hasWork() }.reason)
            assertEquals(raw, disk.value)
        }
        val disk = MemorySecrets(); val store = DeviceRegistrationStore(disk) { 1 }
        repeat(256) { store.prepare("account$it") }; val before = disk.value
        assertEquals(CredentialRecoveryFailure.Reason.CapacityExceeded, assertFailsWith<CredentialRecoveryFailure> { store.prepare("overflow") }.reason)
        assertEquals(before, disk.value); store.discardPendingRegistrations(); assertEquals(256, store.jobs().size)
        assertFalse(store.activity().awaitingRegistration)
    }
    @Test fun duplicatePendingAndAbandonedOperationsAreRejectedInsteadOfReplayed() = runTest {
        val disk = MemorySecrets(); val store = DeviceRegistrationStore(disk) { 0 }; val pending = store.prepare("account")
        val raw = Json.parseToJsonElement(disk.value!!).jsonObject
        disk.value = JsonObject(raw + ("abandoned" to buildJsonObject { put(pending.cancellation.operation,
            Json.encodeToJsonElement(RegistrationCancellationJob(pending.cancellation, 0, 0))) })).toString()
        val damaged = disk.value
        assertEquals(CredentialRecoveryFailure.Reason.Malformed, assertFailsWith<CredentialRecoveryFailure> { store.prepare("account") }.reason)
        assertEquals(damaged, disk.value)
    }
}
