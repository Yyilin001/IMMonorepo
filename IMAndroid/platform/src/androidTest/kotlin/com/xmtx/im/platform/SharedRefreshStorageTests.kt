package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID

class SharedRefreshStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private class Transport(val credential: Credentials) : AccountTransport {
        val entered = CompletableDeferred<Unit>(); val gate = CompletableDeferred<Unit>()
        override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
            check(path.endsWith("refresh")); entered.complete(Unit); gate.await()
            return buildJsonObject {
                put("userID", credential.userId.value); put("deviceID", credential.deviceId.value)
                put("accessToken", "successor-access"); put("accessTokenExpiresAtMilliseconds", 200_000)
                put("refreshCredential", "successor-refresh"); put("revocationCredential", credential.revocationCredential)
                put("revocationCredentialExpiresAtMilliseconds", credential.revocationExpiresAt)
            }
        }
    }
    private fun fixture(body: suspend CoroutineScope.(String, KeystoreCredentialStore, FileLocalExitMarker, Transport, AuthSession) -> Unit) = runBlocking {
        val name = "credential-shared-refresh-${UUID.randomUUID()}"
        val store = KeystoreCredentialStore(context, name); val marker = FileLocalExitMarker(context, name)
        val c = Credentials(UserId(UUID.randomUUID().toString()), DeviceId(UUID.randomUUID().toString()),
            "original-access", 1, "original-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 1000000)
        val transport = Transport(c); val auth = AuthSession(store, transport, marker) { 0 }
        try { withTimeout(10_000) {
            store.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(c)) }.toString())
            body(name, store, marker, transport, auth)
        } } finally {
            withContext(NonCancellable) { auth.cancelRefreshAndDrain() }
            val markerId = MessageDigest.getInstance("SHA-256").digest(name.toByteArray()).joinToString("") { "%02x".format(it) }
            for (suffix in listOf("", ".bak", ".new")) {
                File(context.noBackupFilesDir, "$name.enc$suffix").delete()
                File(context.noBackupFilesDir, "local-exit-$markerId.json$suffix").delete()
            }
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("com.xmtx.im.$name.v1") }
        }
    }

    @Test fun cancelledWaiterStillLeavesACommittedSuccessorForANewSession() = fixture { name, _, marker, transport, auth ->
        val waiting = async { auth.access() }; transport.entered.await(); waiting.cancelAndJoin()
        transport.gate.complete(Unit)
        while (auth.current()!!.accessExpiresAt != 200_000L) delay(5)
        val restored = AuthSession(KeystoreCredentialStore(context, name), transport, FileLocalExitMarker(context, name)) { 0 }
        val successor = restored.current()!!
        assertEquals("successor-access", successor.accessToken); assertEquals("successor-refresh", successor.refreshCredential)
        assertEquals(transport.credential.deviceId, successor.deviceId); assertFalse(marker.isPending())
        assertFalse(File(context.noBackupFilesDir, "$name.enc").readBytes().toString(Charsets.UTF_8).contains("successor-refresh"))
    }

    @Test fun exitDuringRefreshPreservesOriginalJournalAndDurablyBlocksANewSession() = fixture { name, store, marker, transport, auth ->
        val waiting = async { auth.access() }; transport.entered.await(); val before = store.read()
        auth.prepareLocalExit(); waiting.join(); assertTrue(waiting.isCancelled); assertTrue(marker.isPending())
        assertEquals(before, store.read())
        val restored = AuthSession(KeystoreCredentialStore(context, name), transport, FileLocalExitMarker(context, name)) { 0 }
        assertNull(restored.current()); assertTrue(restored.hasCleanup())
        assertEquals(AuthSessionState.CleanupPending, restored.currentState())
    }
}
