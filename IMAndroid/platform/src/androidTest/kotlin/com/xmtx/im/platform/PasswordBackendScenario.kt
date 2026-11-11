package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import java.io.IOException
import java.util.UUID

internal suspend fun verifyPasswordBackend(context: Context, transport: AccountClient, run: String) {
    val account = "lifecycle_$run"; val firstPassword = UUID.randomUUID().toString() + "aA1!"
    val secondPassword = UUID.randomUUID().toString() + "bB2!"; val recoveredPassword = UUID.randomUUID().toString() + "cC3!"
    val sessions = mutableListOf<AuthSession>()
    fun auth(): AuthSession = AuthSession(KeystoreSecretStore(context, "e2e-$run-password-${sessions.size}"), transport).also(sessions::add)
    fun device() = DeviceId(UUID.randomUUID().toString())
    val client = PasswordLifecycleClient(transport)
    suspend fun revoked(session: AuthSession) {
        val credentials = requireNotNull(session.current())
        try { session.access(rejectedAccess = credentials); fail("old device refreshed after password replacement") }
        catch(error: ClientFailure.Http) { assertTrue(error.status in setOf(401,403)) }
    }
    try {
        val first = auth(); first.login(account, firstPassword, true, account, "密码生命周期验收")
        val second = auth(); second.login(account, firstPassword)
        val recoveryCode = PasswordLifecycleClient.generateRecoveryCode()
        var requests = 0
        val losingTransport = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                requests++; transport.post(path, payload, accessToken, expectedStatus); throw IOException("response lost after commit")
            }
        }
        try { PasswordLifecycleClient(losingTransport).perform(PasswordAction.RecoveryCode, account, device(), firstPassword, recoveryCode = recoveryCode); fail("lost response was accepted") }
        catch(_: IOException) { }
        assertEquals(1, requests)
        // Explicitly retry the SAME externally saved code; no replacement generated on uncertainty.
        client.perform(PasswordAction.RecoveryCode, account, device(), firstPassword, recoveryCode = recoveryCode)
        assertNotNull(first.access(rejectedAccess = first.current())); assertNotNull(second.access(rejectedAccess = second.current()))
        client.perform(PasswordAction.Change, account, device(), firstPassword, secondPassword)
        revoked(first); revoked(second)
        try { client.perform(PasswordAction.Recover, account, device(), next = recoveredPassword, recoveryCode = recoveryCode); fail("password change retained old recovery code") }
        catch(error: PasswordLifecycleFailure) { assertEquals(PasswordLifecycleFailure.Reason.AuthenticationRejected, error.reason) }
        try { auth().login(account, firstPassword); fail("old password accepted") }
        catch(error: ClientFailure.Http) { assertEquals(401, error.status) }
        val replacement = auth(); replacement.login(account, secondPassword)
        val secondCode = PasswordLifecycleClient.generateRecoveryCode()
        client.perform(PasswordAction.RecoveryCode, account, device(), secondPassword, recoveryCode = secondCode)
        requests = 0
        try { PasswordLifecycleClient(losingTransport).perform(PasswordAction.Recover, account, device(), next = recoveredPassword, recoveryCode = secondCode); fail("lost reset response was accepted") }
        catch(_: IOException) { }
        assertEquals(1, requests); revoked(replacement)
        val recovered = auth(); recovered.login(account, recoveredPassword)
        try { client.perform(PasswordAction.Recover, account, device(), next = secondPassword, recoveryCode = secondCode); fail("consumed recovery code accepted again") }
        catch(error: PasswordLifecycleFailure) { assertEquals(PasswordLifecycleFailure.Reason.AuthenticationRejected, error.reason) }
        assertNotNull(recovered.access(rejectedAccess = recovered.current()))
    } finally {
        withContext(NonCancellable) { withTimeout(45000) { sessions.forEach { it.logout() } } }
    }
}
