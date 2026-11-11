package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.util.UUID

internal suspend fun verifyDeviceBackend(context: Context, actor: Credentials, api: AuthenticatedTransport,
    transport: AccountClient, run: String, password: String) {
    val targetSecrets = KeystoreSecretStore(context, "e2e-$run-device-target")
    val lateSecrets = KeystoreSecretStore(context, "e2e-$run-device-late")
    val securityName = "e2e-$run-device-security"
    val security = KeystoreSecretStore(context, securityName)
    val targetAuth = AuthSession(targetSecrets, transport); val lateAuth = AuthSession(lateSecrets, transport)
    try {
        val target = targetAuth.login("device_${run}_a", password)
        val client = DeviceSessionClient(api, actor.deviceId)
        // Exercise actual opaque pagination with two query parameters.
        val firstPage = client.list(pageSize = 1); assertEquals(1, firstPage.sessions.size); assertNotNull(firstPage.cursor)
        val secondPage = client.list(firstPage.cursor, 1); assertEquals(1, secondPage.sessions.size)
        assertNotEquals(firstPage.sessions.single().device, secondPage.sessions.single().device)
        val journal = DeviceRevocationJournal(security, actor.userId, actor.deviceId)
        val original = DeviceRevocationService(actor.userId, actor.deviceId, client, journal)
        val baseline = original.baseline()
        assertTrue(target.deviceId in baseline.targets); assertFalse(actor.deviceId in baseline.targets)
        val command = DeviceRevocationCommand(UUID.randomUUID().toString().uppercase(), baseline, null, baseline.expiresAt)
        val work = original.enqueue(command)
        // Logging in after the observed baseline must not widen "all observed others".
        val late = lateAuth.login("device_${run}_a", password); assertFalse(late.deviceId in command.targets)
        journal.compareAndSet(persistentListOf(work), persistentListOf(work.copy(unknown = true, attempts = 1)))
        val committed = (client.execute(command, false) as DeviceRevocationResult.Receipt).receipt
        assertEquals(DeviceRevocationOutcome.Revoked, committed.outcome); original.close()
        val reopened = DeviceRevocationJournal(KeystoreSecretStore(context, securityName), actor.userId, actor.deviceId)
        assertNull(reopened.read().single().receipt)
        DeviceRevocationService(actor.userId, actor.deviceId, client, reopened).flush()
        assertEquals(committed, reopened.read().single().receipt)
        assertEquals(committed, (client.execute(command, false) as DeviceRevocationResult.Receipt).receipt)
        try { targetAuth.access(rejectedAccess = target); fail("revoked device refreshed credentials") }
        catch(error: ClientFailure.Http) { assertTrue(error.status in setOf(401,403)) }
        assertEquals(late.deviceId, lateAuth.access(rejectedAccess = late).deviceId)
        assertTrue(client.list().sessions.any { it.device == actor.deviceId && it.current })
        assertTrue(client.list().sessions.any { it.device == late.deviceId }); assertFalse(client.list().sessions.any { it.device == target.deviceId })
        // A persisted but never attempted command loses submission permission on reopening.
        val service = DeviceRevocationService(actor.userId, actor.deviceId, client, reopened)
        val fresh = service.baseline()
        val closeCommand = DeviceRevocationCommand(UUID.randomUUID().toString().uppercase(), fresh, late.deviceId, fresh.expiresAt)
        service.enqueue(closeCommand); service.close()
        val recovered = DeviceRevocationService(actor.userId, actor.deviceId, client,
            DeviceRevocationJournal(KeystoreSecretStore(context, securityName), actor.userId, actor.deviceId))
        recovered.flush()
        assertEquals(DeviceRevocationOutcome.Closed, recovered.works().first { it.command == closeCommand }.receipt?.outcome)
        assertEquals(DeviceRevocationOutcome.Closed, (client.execute(closeCommand, false) as DeviceRevocationResult.Receipt).receipt.outcome)
        assertTrue(client.list().sessions.any { it.device == late.deviceId }); recovered.close()
    } finally {
        withContext(NonCancellable) { withTimeout(30000) { targetAuth.logout(); lateAuth.logout() } }
        security.delete()
    }
}
