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

class QueuedLogoutStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    @Test fun encryptedQueueSurvivesAuthKeyRetirementAndAColdOwnerCompletesItWithoutAccessTokens() = runBlocking {
        val name = "credential-queued-logout-${UUID.randomUUID()}"; val domain = hash(name)
        val secrets = KeystoreCredentialStore(context, name); val marker = FileLocalExitMarker(context, name)
        val owner = KeystoreIssuedCredentialRecovery(context, name)
        val c = Credentials(UserId("user"), DeviceId(UUID.randomUUID().toString()), "private-access", 1, "private-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 2)
        var requests = 0; var expectedOperation: String? = null
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                requests++; assertEquals("/v2/device-credentials/revoke", path); assertNull(accessToken)
                assertEquals(setOf("credential", "operationID"), payload.keys)
                assertEquals(expectedOperation, payload.getValue("operationID").jsonPrimitive.content)
                return buildJsonObject {}
            }
        }
        try {
            secrets.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(c)) }.toString())
            AuthSession(secrets, api, marker, owner.receipts, owner.registrations).logout()
            assertEquals(0, requests); assertNull(secrets.read()); assertFalse(marker.isPending())
            val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }; assertFalse(keys.containsAlias("com.xmtx.im.$name.v1"))
            val queueFile = File(context.noBackupFilesDir, "credential-revocations-$domain.enc"); assertTrue(queueFile.exists())
            assertFalse(queueFile.readBytes().toString(Charsets.UTF_8).contains(c.revocationCredential))
            val plain = KeystoreCredentialStore(context, "credential-revocations-$domain").read()!!
            assertFalse(plain.contains(c.accessToken)); assertFalse(plain.contains(c.refreshCredential))
            val cold = KeystoreIssuedCredentialRecovery(context, name); val queued = cold.revocations.jobs().single()
            assertEquals(c.deviceId, queued.intent.device); expectedOperation = queued.intent.operation
            coroutineScope {
                val task = launch { cold.runner(api).run() }
                withTimeout(5000) { cold.revocations.statusUpdates().first { it == CredentialRevocationStatus.Empty } }
                task.cancelAndJoin()
            }
            assertEquals(1, requests); assertFalse(queueFile.exists()); assertFalse(keys.containsAlias("com.xmtx.im.credential-revocations-$domain.v1"))
        } finally {
            val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            for (journal in listOf(name) + listOf("receipts", "revocations", "registrations").map { "credential-$it-$domain" }) {
                for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "$journal.enc$suffix").delete()
                keys.deleteEntry("com.xmtx.im.$journal.v1")
            }
            for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "local-exit-$domain.json$suffix").delete()
        }
    }
}
