package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class IssuedCredentialRecoveryTests {
    private fun operation() = UUID.randomUUID().toString().uppercase()
    private fun credentials() = Credentials(UserId("owner"), DeviceId(UUID.randomUUID().toString()), "private-access", 1,
        "private-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 2)
    private suspend fun failure(reason: CredentialRecoveryFailure.Reason, body: suspend () -> Unit) {
        val e = assertFailsWith<CredentialRecoveryFailure> { body() }; assertEquals(reason, e.reason); assertNull(e.cause)
    }
    @Test fun receiptContainsOnlyRevocationAuthorityAndRequiresExactAdoption() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(MemorySecrets()); val store = IssuedCredentialRecoveryStore(disk, queue)
        val c = credentials(); val op = operation(); val receipt = store.receive(c, op)
        assertFalse(disk.value!!.contains(c.accessToken)); assertFalse(disk.value!!.contains(c.refreshCredential))
        assertFalse(receipt.toString().contains(c.revocationCredential)); assertTrue(queue.jobs().isEmpty())
        assertEquals(receipt, store.receive(c.copy(accessToken = "rotated", refreshCredential = "rotated-refresh"), op))
        failure(CredentialRecoveryFailure.Reason.Conflict) { store.receive(c.copy(userId = UserId("other")), op) }
        failure(CredentialRecoveryFailure.Reason.Conflict) { store.adopt(receipt.copy(expiresAt = 3)) }
        store.adopt(receipt); assertNull(disk.value)
        failure(CredentialRecoveryFailure.Reason.Conflict) { store.adopt(receipt) }
        store.abandon(receipt); assertTrue(queue.jobs().isEmpty())
    }
    @Test fun abandonmentIsDurableBeforeQueueHandoffAndCanResumeWithNewOwners() = runTest {
        val disk = MemorySecrets(); val outbox = MemorySecrets(); val queue = CredentialRevocationQueue(outbox)
        val store = IssuedCredentialRecoveryStore(disk, queue); val receipt = store.receive(credentials(), operation())
        outbox.failWrite = true
        failure(CredentialRecoveryFailure.Reason.Unavailable) { store.abandon(receipt) }
        assertTrue(disk.value!!.contains("Abandoned")); assertNull(outbox.value)
        failure(CredentialRecoveryFailure.Reason.Conflict) { store.adopt(receipt) }
        outbox.failWrite = false
        IssuedCredentialRecoveryStore(disk, CredentialRevocationQueue(outbox)).drainAbandoned()
        assertNull(disk.value); assertEquals(receipt, queue.jobs().single().intent)
    }
    @Test fun handoffCrashPreservesExistingOperationRetryAndPauseState() = runTest {
        val disk = MemorySecrets(); var failDelete = true
        val receipts = object : SecretStore by disk { override suspend fun delete() { if (failDelete) throw IOException(); disk.delete() } }
        val queue = CredentialRevocationQueue(MemorySecrets()); val store = IssuedCredentialRecoveryStore(receipts, queue)
        val c = credentials(); val existing = CredentialRevocationIntent.received(c, operation()); queue.enqueue(existing)
        val original = queue.jobs().single(); queue.recordFailure(original, 9000, CredentialRevocationJob.Pause.OperationConflict)
        val before = queue.jobs().single(); val receipt = store.receive(c, operation())
        failure(CredentialRecoveryFailure.Reason.Unavailable) { store.abandon(receipt) }
        assertEquals(before, queue.jobs().single()); assertNotNull(disk.value)
        failDelete = false; store.drainAbandoned(); assertNull(disk.value); assertEquals(before, queue.jobs().single())
    }
    @Test fun coldRecoveryRecognizesRotationButNotRevocationAuthorityOrExpiryChanges() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(MemorySecrets()); val c = credentials()
        IssuedCredentialRecoveryStore(disk, queue).receive(c, operation())
        IssuedCredentialRecoveryStore(disk, queue).recoverUnclaimed(c.copy(accessToken = "rotated", refreshCredential = "new-refresh"))
        assertNull(disk.value); assertTrue(queue.jobs().isEmpty())
        val receipt = IssuedCredentialRecoveryStore(disk, queue).receive(c, operation())
        IssuedCredentialRecoveryStore(disk, queue).recoverUnclaimed(c.copy(revocationExpiresAt = 3))
        assertNull(disk.value); assertEquals(receipt, queue.jobs().single().intent)
    }
    @Test fun alreadyAbandonedReceiptCannotBeReadoptedByAMatchingAuthRecord() = runTest {
        val disk = MemorySecrets(); val outbox = MemorySecrets(); val queue = CredentialRevocationQueue(outbox)
        val store = IssuedCredentialRecoveryStore(disk, queue); val c = credentials(); val receipt = store.receive(c, operation())
        outbox.failWrite = true; failure(CredentialRecoveryFailure.Reason.Unavailable) { store.abandon(receipt) }
        outbox.failWrite = false; store.recoverUnclaimed(c)
        assertEquals(receipt, queue.jobs().single().intent); assertNull(disk.value)
    }
    @Test fun corruptOrUnavailableLedgersAreNeverTreatedAsEmptyOrRepaired() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk)
        for (raw in listOf("{bad", "{\"version\":2,\"jobs\":{}}", "{\"version\":1,\"jobs\":null}")) {
            disk.value = raw; failure(CredentialRecoveryFailure.Reason.Malformed) { queue.jobs() }; assertEquals(raw, disk.value)
        }
        val inaccessible = object : SecretStore by disk { override suspend fun read(): String? = throw IOException("sensitive detail") }
        failure(CredentialRecoveryFailure.Reason.Unavailable) { CredentialRevocationQueue(inaccessible).jobs() }
        val receipts = IssuedCredentialRecoveryStore(disk, CredentialRevocationQueue(MemorySecrets()))
        failure(CredentialRecoveryFailure.Reason.Malformed) { receipts.recoverUnclaimed(null) }
    }
    @Test fun queueRejectsMismatchedKeysDuplicateTargetsAndInvalidAttemptCounts() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk)
        val intent = CredentialRevocationIntent.received(credentials(), operation()); queue.enqueue(intent)
        val valid = Json.parseToJsonElement(disk.value!!).jsonObject; val jobs = valid.getValue("jobs").jsonObject
        val job = jobs.values.single().jsonObject
        val variants = listOf(
            JsonObject(mapOf(operation() to job)),
            JsonObject(jobs + (operation().let { it to JsonObject(job + ("intent" to JsonObject(job.getValue("intent").jsonObject + ("operation" to JsonPrimitive(it)))))})),
            JsonObject(mapOf(intent.operation to JsonObject(job + ("attempts" to JsonPrimitive(-1)))))
        )
        for (bad in variants) {
            val raw = JsonObject(valid + ("jobs" to bad)).toString(); disk.value = raw
            failure(CredentialRecoveryFailure.Reason.Malformed) { queue.jobs() }; assertEquals(raw, disk.value)
        }
    }
    @Test fun capacityAndConflictsPreserveTheExistingEvidence() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk)
        val receiptsDisk = MemorySecrets(); val receipts = IssuedCredentialRecoveryStore(receiptsDisk, queue)
        repeat(256) { val c = credentials(); val op = operation(); queue.enqueue(CredentialRevocationIntent.received(c, op)); receipts.receive(c, op) }
        val before = disk.value; val received = receiptsDisk.value
        failure(CredentialRecoveryFailure.Reason.CapacityExceeded) { queue.enqueue(CredentialRevocationIntent.received(credentials(), operation())) }
        failure(CredentialRecoveryFailure.Reason.CapacityExceeded) { receipts.receive(credentials(), operation()) }
        assertEquals(before, disk.value); assertEquals(received, receiptsDisk.value)
        val existing = queue.jobs().first().intent
        failure(CredentialRecoveryFailure.Reason.Conflict) { queue.enqueue(existing.copy(operation = operation())) }
        queue.enqueue(existing); assertEquals(before, disk.value)
    }
    @Test fun staleCompletionsCannotOverrideFailureOrExplicitRetryAndExpiryDoesNotSettleWork() = runTest {
        val queue = CredentialRevocationQueue(MemorySecrets()); queue.enqueue(CredentialRevocationIntent.received(credentials(), operation()))
        val old = queue.due(Long.MAX_VALUE).single()
        assertTrue(queue.recordFailure(old, 1234, CredentialRevocationJob.Pause.InvalidCredential))
        assertFalse(queue.complete(old)); assertFalse(queue.recordFailure(old, 10))
        assertTrue(queue.due(Long.MAX_VALUE).isEmpty()); assertEquals(CredentialRevocationStatus.Paused, queue.status())
        queue.retryPaused(); val resumed = queue.due(0).single()
        assertEquals(old.intent, resumed.intent); assertEquals(1, resumed.attempts)
        assertTrue(queue.complete(resumed)); assertEquals(CredentialRevocationStatus.Empty, queue.status())
    }
    @Test fun failedAndSilentWritesDoNotPublishSuccessOrLoseReceipts() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk)
        val states = mutableListOf<CredentialRevocationStatus>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { queue.statusUpdates().toList(states) }
        disk.failWrite = true
        failure(CredentialRecoveryFailure.Reason.Unavailable) { queue.enqueue(CredentialRevocationIntent.received(credentials(), operation())) }
        assertEquals(listOf(CredentialRevocationStatus.Empty), states)
        val silent = object : SecretStore by disk { override suspend fun write(value: String) {} }
        failure(CredentialRecoveryFailure.Reason.Unavailable) { CredentialRevocationQueue(silent).enqueue(CredentialRevocationIntent.received(credentials(), operation())) }
        disk.failWrite = false
        val receipts = IssuedCredentialRecoveryStore(object : SecretStore by disk { override suspend fun delete() {} }, queue)
        val receipt = receipts.receive(credentials(), operation())
        failure(CredentialRecoveryFailure.Reason.Unavailable) { receipts.adopt(receipt) }; assertNotNull(disk.value)
    }
    @Test fun cancellationDuringAnAdmittedCommitFinishesPersistenceAndWakesTheRunner() = runTest {
        val disk = MemorySecrets(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val backing = object : SecretStore by disk { override suspend fun write(value: String) { entered.complete(Unit); release.await(); disk.write(value) } }
        val queue = CredentialRevocationQueue(backing); val intent = CredentialRevocationIntent.received(credentials(), operation())
        val write = launch { queue.enqueue(intent) }; entered.await(); write.cancel(); runCurrent()
        assertFalse(write.isCompleted); release.complete(Unit); write.join()
        assertEquals(intent, queue.jobs().single().intent); assertEquals(1, queue.changes.value)
    }
}
