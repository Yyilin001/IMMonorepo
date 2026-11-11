package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID

class IssuedCredentialRecoveryStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun operation() = UUID.randomUUID().toString().uppercase()
    private fun credentials() = Credentials(UserId(UUID.randomUUID().toString()), DeviceId(UUID.randomUUID().toString()),
        "private-access-token", 1, "private-refresh-token", "imv2-revoke-v1.${"A".repeat(43)}", 2)
    private fun fixture(body: suspend (String, String) -> Unit) = runBlocking {
        val namespace = "issued-recovery-${UUID.randomUUID()}"
        val domain = MessageDigest.getInstance("SHA-256").digest(namespace.toByteArray()).joinToString("") { "%02x".format(it) }
        try { body(namespace, domain) }
        finally {
            val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            for (kind in listOf("receipts", "revocations", "registrations")) {
                val name = "credential-$kind-$domain"
                for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "$name.enc$suffix").delete()
                keys.deleteEntry("com.xmtx.im.$name.v1")
            }
        }
    }
    @Test fun pendingRegistrationAndPausedCancellationSurviveEncryptedOwnerRecreation() = fixture { namespace, domain ->
        val first = KeystoreIssuedCredentialRecovery(context, namespace)
        val pending = first.registrations.prepare("account").load()
        val file = File(context.noBackupFilesDir, "credential-registrations-$domain.enc")
        assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(pending.proof))
        val cold = KeystoreIssuedCredentialRecovery(context, namespace)
        assertEquals(pending, cold.registrations.prepare("ACCOUNT").load())
        cold.registrations.recoverUnclaimed(null)
        var reject = true
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                if (reject) throw ClientFailure.Http(409)
                return buildJsonObject {}
            }
        }
        coroutineScope {
            val task = launch { cold.cancellationRunner(api).run() }
            withTimeout(5000) { cold.registrations.activityUpdates().first { it.cancellations == CredentialRevocationStatus.Paused } }
            task.cancelAndJoin()
        }
        val paused = cold.registrations.jobs().single()
        val next = KeystoreIssuedCredentialRecovery(context, namespace)
        assertEquals(paused, next.registrations.jobs().single()); assertFalse(next.registrations.activity().awaitingRegistration)
        next.registrations.retryPaused(); assertEquals(pending, next.registrations.jobs().single().cancellation)
        reject = false
        coroutineScope {
            val task = launch { next.cancellationRunner(api).run() }
            withTimeout(5000) { next.registrations.activityUpdates().first { it.cancellations == CredentialRevocationStatus.Empty } }
            task.cancelAndJoin()
        }
        assertFalse(file.exists())
    }
    @Test fun unreadableRegistrationLedgerNeverBecomesPermissionToIssueAnotherDevice() = fixture { namespace, domain ->
        val owner = KeystoreIssuedCredentialRecovery(context, namespace); owner.registrations.prepare("account")
        val file = File(context.noBackupFilesDir, "credential-registrations-$domain.enc"); val valid = file.readBytes()
        val damaged = valid.copyOf(); damaged[damaged.lastIndex] = (damaged.last().toInt() xor 1).toByte(); file.writeBytes(damaged)
        failure(CredentialRecoveryFailure.Reason.Malformed) { owner.registrations.prepare("account") }
        assertArrayEquals(damaged, file.readBytes()); file.writeBytes(valid)
        val alias = "com.xmtx.im.credential-registrations-$domain.v1"
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }; keys.deleteEntry(alias)
        failure(CredentialRecoveryFailure.Reason.Unavailable) { owner.registrations.discardPendingRegistrations() }
        assertFalse(keys.containsAlias(alias)); assertArrayEquals(valid, file.readBytes())
    }
    private suspend fun failure(reason: CredentialRecoveryFailure.Reason, body: suspend () -> Unit) {
        try { body(); fail("accepted inaccessible recovery record") }
        catch (e: CredentialRecoveryFailure) { assertEquals(reason, e.reason); assertNull(e.cause) }
    }
    @Test fun creationDoesNoIoAndNewOwnerRecognizesDurablyAdoptedRotatedCredentials() = fixture { namespace, domain ->
        val owner = KeystoreIssuedCredentialRecovery(context, namespace)
        val file = File(context.noBackupFilesDir, "credential-receipts-$domain.enc"); assertFalse(file.exists())
        val c = credentials(); owner.receipts.receive(c, operation()); assertTrue(file.exists())
        val raw = KeystoreCredentialStore(context, "credential-receipts-$domain").read()!!
        assertFalse(raw.contains(c.accessToken)); assertFalse(raw.contains(c.refreshCredential)); assertTrue(raw.contains(c.revocationCredential))
        assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(c.revocationCredential))
        val restored = KeystoreIssuedCredentialRecovery(context, namespace)
        restored.receipts.recoverUnclaimed(c.copy(accessToken = "rotated", refreshCredential = "rotated-refresh"))
        assertFalse(file.exists()); assertEquals(CredentialRevocationStatus.Empty, restored.revocations.status())
    }
    @Test fun unclaimedReceiptHandsOffEncryptedAuthorityThatSurvivesOwnerRecreation() = fixture { namespace, domain ->
        val c = credentials(); val owner = KeystoreIssuedCredentialRecovery(context, namespace)
        val receipt = owner.receipts.receive(c, operation())
        val restored = KeystoreIssuedCredentialRecovery(context, namespace); restored.receipts.recoverUnclaimed(null)
        assertFalse(File(context.noBackupFilesDir, "credential-receipts-$domain.enc").exists())
        val file = File(context.noBackupFilesDir, "credential-revocations-$domain.enc"); assertTrue(file.exists())
        assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(c.revocationCredential))
        val next = KeystoreIssuedCredentialRecovery(context, namespace)
        assertEquals(receipt, next.revocations.jobs().single().intent)
        assertEquals(receipt, next.revocations.due(1_000_000).single().intent)
        assertEquals(CredentialRevocationStatus.Pending, next.revocations.status())
    }
    @Test fun recoveredReceiptKeepsAnExistingPausedQueueOperationAndAttempts() = fixture { namespace, _ ->
        val c = credentials(); val owner = KeystoreIssuedCredentialRecovery(context, namespace)
        owner.revocations.enqueue(CredentialRevocationIntent.received(c, operation()))
        owner.revocations.recordFailure(owner.revocations.jobs().single(), 5000, CredentialRevocationJob.Pause.InvalidCredential)
        val before = owner.revocations.jobs().single()
        owner.receipts.receive(c, operation())
        val restored = KeystoreIssuedCredentialRecovery(context, namespace); restored.receipts.recoverUnclaimed(null)
        assertEquals(before, restored.revocations.jobs().single()); assertEquals(CredentialRevocationStatus.Paused, restored.revocations.status())
        restored.revocations.retryPaused(); val resumed = KeystoreIssuedCredentialRecovery(context, namespace).revocations.jobs().single()
        assertEquals(before.intent, resumed.intent); assertEquals(before.attempts, resumed.attempts); assertNull(resumed.pause)
    }
    @Test fun corruptionAndMissingKeysPreserveCiphertextWithoutInventingAnEmptyLedger() = fixture { namespace, domain ->
        val owner = KeystoreIssuedCredentialRecovery(context, namespace); val c = credentials()
        owner.receipts.receive(c, operation())
        val file = File(context.noBackupFilesDir, "credential-receipts-$domain.enc"); val valid = file.readBytes()
        val damaged = valid.copyOf(); damaged[damaged.lastIndex] = (damaged.last().toInt() xor 1).toByte(); file.writeBytes(damaged)
        failure(CredentialRecoveryFailure.Reason.Malformed) { owner.receipts.recoverUnclaimed(null) }
        assertArrayEquals(damaged, file.readBytes()); assertTrue(owner.revocations.jobs().isEmpty())
        file.writeBytes(valid)
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }; val alias = "com.xmtx.im.credential-receipts-$domain.v1"
        keys.deleteEntry(alias)
        failure(CredentialRecoveryFailure.Reason.Unavailable) { owner.receipts.recoverUnclaimed(null) }
        failure(CredentialRecoveryFailure.Reason.Unavailable) { owner.receipts.receive(c, operation()) }
        assertFalse(keys.containsAlias(alias)); assertArrayEquals(valid, file.readBytes())
    }
}
