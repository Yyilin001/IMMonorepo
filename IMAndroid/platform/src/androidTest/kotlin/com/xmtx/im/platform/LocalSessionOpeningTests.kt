package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalSessionOpeningTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val file = accountDatabaseFile(context, user, device)
        val credentials = Credentials(user, device, "fixture-access", 1, "fixture-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 1)
        var record: String? = buildJsonObject { put("credentials", Json.encodeToJsonElement(credentials)) }.toString()
        var reads = 0; var onRead: suspend (Int) -> Unit = {}; var calls = 0
        val secret = object : SecretStore {
            override suspend fun read(): String? { onRead(++reads); return record }
            override suspend fun write(value: String) { record = value }
            override suspend fun delete() { record = null }
        }
        val api = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                calls++; check(path.endsWith("revoke")); return buildJsonObject {}
            }
        }
        val auth = AuthSession(secret, api)
        fun close() { SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun expiredDeviceCredentialsOpenLocallyWithoutNetworkAndForeignEpochCannotCreateFiles() = runBlocking {
        val f = Fixture()
        try {
            val identity = f.auth.localAccountIdentity()
            val bootstrap = LocalStoreBootstrapper(context)
            try { bootstrap.open(AuthSession(f.secret, f.api), identity).close(); fail("foreign epoch opened") }
            catch (_: ClientFailure.SessionInvalidated) {}
            assertFalse(f.file.exists())
            val before = f.record
            bootstrap.open(f.auth, identity).use { assertTrue(it.appSnapshot().conversations.isEmpty()) }
            assertEquals(before, f.record); assertEquals(0, f.calls)
            f.auth.requireLocalIdentity(identity)
        } finally { f.close() }
    }

    @Test fun changedIdentityDuringDatabaseOpeningClosesTheAllocatedStore() = runBlocking {
        val f = Fixture()
        try {
            val identity = f.auth.localAccountIdentity()
            var loads = 0; var value: LocalInstallationBinding? = null
            val bindings = object : InstallationBindingStore {
                override suspend fun load(): LocalInstallationBinding? {
                    if (++loads == 2) f.auth.logout()
                    return value
                }
                override suspend fun save(binding: LocalInstallationBinding) { value = binding }
                override suspend fun delete() { value = null }
            }
            try { LocalStoreBootstrapper(context, bindings).open(f.auth, identity).close(); fail("retired identity opened") }
            catch (_: ClientFailure.SessionInvalidated) {}
            assertTrue(f.file.isFile); assertNull(f.auth.current())
            // Exclusive recovery admission proves no lost SQLite handle survived the post-open fence.
            LocalDatabaseAccess.acquire(f.file, recovery = true).close()
        } finally { f.close() }
    }

    @Test fun cancellationDuringThePostOpenCredentialReadClosesTheCapturedStore() = runBlocking {
        val f = Fixture()
        try {
            val identity = f.auth.localAccountIdentity(); val entered = CompletableDeferred<Unit>()
            f.onRead = { if (it == 3) { entered.complete(Unit); awaitCancellation() } }
            val opening = launch(Dispatchers.Default) { LocalStoreBootstrapper(context).open(f.auth, identity).close() }
            withTimeout(10_000) { entered.await() }
            opening.cancelAndJoin(); f.onRead = {}
            assertTrue(f.file.exists()); LocalDatabaseAccess.acquire(f.file, recovery = true).close()
            assertEquals(0, f.calls); assertEquals(identity, f.auth.localAccountIdentity())
        } finally { f.close() }
    }
}
