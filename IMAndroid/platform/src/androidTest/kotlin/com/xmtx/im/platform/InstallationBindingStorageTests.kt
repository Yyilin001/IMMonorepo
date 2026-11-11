package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class InstallationBindingStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val account = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString())
    private val file get() = accountDatabaseFile(context, account, device)
    private class Bindings : InstallationBindingStore {
        var value: LocalInstallationBinding? = null
        var error: Exception? = null
        var saves = 0
        override suspend fun load(): LocalInstallationBinding? { error?.let { throw it }; return value }
        override suspend fun save(binding: LocalInstallationBinding) { saves++; value = binding }
        override suspend fun delete() { value = null }
    }
    private suspend fun failure(reason: LocalStoreFailure.Reason, action: suspend () -> Unit) {
        try { action(); fail("expected $reason") } catch (error: LocalStoreFailure) { assertEquals(reason, error.reason) }
    }
    private fun cleanup() { SQLiteDatabase.deleteDatabase(file) }

    @Test fun boundStoreReopensAndReadOnlyVerificationLeavesBytesUnchanged() = runBlocking {
        val bindings = Bindings(); val bootstrapper = LocalStoreBootstrapper(context, bindings)
        try {
            bootstrapper.open(account, device).use { assertTrue(it.snapshot().messages.isEmpty()) }
            val binding = requireNotNull(bindings.value)
            val before = file.readBytes()
            assertEquals(binding, bootstrapper.verifyExistingBinding(account, device))
            assertArrayEquals(before, file.readBytes())
            bootstrapper.open(account, device).close()
            assertEquals(1, bindings.saves)
            failure(LocalStoreFailure.Reason.BindingMismatch) { SqliteClientStore(context, account, device).close() }
        } finally { cleanup() }
    }
    @Test fun missingOrForeignAnchorNeverAdoptsOrChangesAnExistingDatabase() = runBlocking {
        val bindings = Bindings(); val bootstrapper = LocalStoreBootstrapper(context, bindings)
        try {
            bootstrapper.open(account, device).close()
            val before = file.readBytes()
            bindings.value = LocalInstallationBinding.create()
            failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.open(account, device).close() }
            assertArrayEquals(before, file.readBytes())
            bindings.value = null
            failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.open(account, device).close() }
            assertArrayEquals(before, file.readBytes()); assertEquals(1, bindings.saves)
        } finally { cleanup() }
    }
    @Test fun legacyDatabaseAndOrphanSidecarArePreservedWithoutCreatingAnAnchor() = runBlocking {
        val bindings = Bindings(); val bootstrapper = LocalStoreBootstrapper(context, bindings)
        val sidecar = java.io.File("${file.path}-wal")
        try {
            SqliteClientStore(context, account, device).close()
            val before = file.readBytes()
            failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.open(account, device).close() }
            assertArrayEquals(before, file.readBytes()); assertNull(bindings.value)
            cleanup(); sidecar.writeText("fixture orphan")
            failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.open(account, device).close() }
            assertEquals("fixture orphan", sidecar.readText()); assertFalse(file.exists()); assertEquals(0, bindings.saves)
        } finally { cleanup(); sidecar.delete() }
    }
    @Test fun accountAndDeviceMustMatchTheStoredRowBeforeSchemaWork() = runBlocking {
        val bindings = Bindings(); val bootstrapper = LocalStoreBootstrapper(context, bindings)
        try {
            bootstrapper.open(account, device).close()
            for (column in listOf("user_id", "device_id")) {
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                    db.execSQL("UPDATE im_installation SET $column=?", arrayOf(UUID.randomUUID().toString()))
                }
                val before = file.readBytes()
                failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.verifyExistingBinding(account, device) }
                failure(LocalStoreFailure.Reason.BindingMismatch) { bootstrapper.open(account, device).close() }
                assertArrayEquals(before, file.readBytes())
                SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                    db.execSQL("UPDATE im_installation SET user_id=?,device_id=?", arrayOf(account.value, device.value))
                }
            }
        } finally { cleanup() }
    }
    @Test fun unavailableBindingAndMissingReadOnlyStoreNeverCreateOrEraseFiles() = runBlocking {
        val bindings = Bindings(); val bootstrapper = LocalStoreBootstrapper(context, bindings)
        try {
            bindings.error = LocalStoreFailure(LocalStoreFailure.Reason.BindingUnavailable)
            failure(LocalStoreFailure.Reason.BindingUnavailable) { bootstrapper.open(account, device).close() }
            assertFalse(file.exists()); assertEquals(0, bindings.saves)
            bindings.error = null; bindings.value = LocalInstallationBinding.create()
            failure(LocalStoreFailure.Reason.StoreUnavailable) { bootstrapper.verifyExistingBinding(account, device) }
            assertFalse(file.exists()); assertEquals(0, bindings.saves)
        } finally { cleanup() }
    }
    @Test fun productionKeystoreBindingIsSeparateAndStableAcrossOwners() = runBlocking {
        val first = LocalStoreBootstrapper(context)
        try {
            first.open(account, device).close()
            val bound = first.verifyExistingBinding(account, device)
            val second = LocalStoreBootstrapper(context)
            second.open(account, device).close()
            assertEquals(bound, second.verifyExistingBinding(account, device))
            assertEquals(bound, KeystoreInstallationBindingStore(context).load())
        } finally { cleanup() }
    }
    @Test fun postOpenBindingChangeClosesTheCapturedStoreWithoutReplacingItsMarker() = runBlocking {
        val bindings = Bindings().apply { value = LocalInstallationBinding.create() }
        var reads = 0
        val changing = object : InstallationBindingStore by bindings {
            override suspend fun load() = if (++reads == 2) LocalInstallationBinding.create() else bindings.value
        }
        try {
            failure(LocalStoreFailure.Reason.BindingMismatch) { LocalStoreBootstrapper(context, changing).open(account, device).close() }
            val stable = LocalStoreBootstrapper(context, bindings)
            assertEquals(bindings.value, stable.verifyExistingBinding(account, device))
            stable.open(account, device).close()
            assertEquals(0, bindings.saves)
        } finally { cleanup() }
    }
    @Test fun cancellationAfterAllocationReleasesTheOpeningGateAndDoesNotAdoptTheHandle() = runBlocking {
        val bindings = Bindings().apply { value = LocalInstallationBinding.create() }
        val allocated = CompletableDeferred<Unit>()
        var reads = 0
        val suspending = object : InstallationBindingStore by bindings {
            override suspend fun load(): LocalInstallationBinding? {
                if (++reads == 2) { allocated.complete(Unit); awaitCancellation() }
                return bindings.value
            }
        }
        val opening = async(Dispatchers.Default) { LocalStoreBootstrapper(context, suspending).open(account, device) }
        try {
            withTimeout(5000) { allocated.await() }
            opening.cancelAndJoin()
            assertTrue(opening.isCancelled)
            withTimeout(5000) { LocalStoreBootstrapper(context, bindings).open(account, device).close() }
        } finally { opening.cancelAndJoin(); cleanup() }
    }
}
