package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.UUID

class InstallationBindingRepairTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val name = "binding-test-${UUID.randomUUID()}"
        val record = File(context.noBackupFilesDir, "$name.enc")
        val bindings = KeystoreInstallationBindingStore(context, name, true)
        val bootstrap = LocalStoreBootstrapper(context, bindings)
        val file = accountDatabaseFile(context, user, device)
        val scope = file.name.removePrefix("im-").removeSuffix(".db")
        val resources = File(context.noBackupFilesDir, "resources-$scope")
        val archives = File(context.noBackupFilesDir, "local-recovery/$scope")
        val keys get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "com.xmtx.im.$name.v1"
        fun damage(missingKey: Boolean) {
            if (missingKey) keys.deleteEntry(alias)
            else { val bytes = record.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); record.writeBytes(bytes) }
        }
        fun cleanup() {
            SQLiteDatabase.deleteDatabase(file)
            for (suffix in listOf("", ".bak", ".new")) { File(record.path + suffix).delete(); File(file.path + ".recovery.json" + suffix).delete() }
            resources.deleteRecursively(); archives.deleteRecursively(); keys.deleteEntry(alias)
        }
    }
    private suspend fun rejected(body: suspend () -> Unit) {
        try { body(); fail("unexpected recovery") } catch (_: LocalStoreFailure) {}
    }
    @Test fun damagedCiphertextAndMissingKeyRebuildOnlyAfterReviewAndPreserveDatabaseAndAttachments() = runBlocking {
        for (missingKey in listOf(false, true)) {
            val f = Fixture()
            val credential = KeystoreSecretStore(context, f.name + "-credentials")
            try {
                credential.write("independent credential")
                val oldIdentity = f.bootstrap.open(f.user, f.device).use { it.databaseIdentity }
                val oldBinding = f.bindings.load(); val original = f.file.readBytes()
                f.resources.mkdir(); File(f.resources, "attachment.txt").writeText("original attachment")
                f.damage(missingKey)
                val damagedRecord = f.record.readBytes()
                rejected { f.bootstrap.open(f.user, f.device).close() }
                val preview = f.bootstrap.previewRecovery(f.user, f.device)
                assertTrue(preview.summary.rebuildsInstallationBinding); assertTrue(preview.summary.includesResources)
                assertArrayEquals(damagedRecord, f.record.readBytes()); assertArrayEquals(original, f.file.readBytes())
                f.bootstrap.recoverLocalStore(preview)
                val replacement = f.bindings.load(); assertNotNull(replacement); assertNotEquals(oldBinding, replacement)
                val archive = f.archives.listFiles()!!.single()
                assertArrayEquals(original, File(archive, "Database").readBytes())
                assertEquals("original attachment", File(archive, "Resources/attachment.txt").readText())
                f.bootstrap.open(f.user, f.device).use { assertNotEquals(oldIdentity, it.databaseIdentity); assertTrue(it.snapshot().messages.isEmpty()) }
                assertEquals(replacement, KeystoreInstallationBindingStore(context, f.name, true).load())
                assertEquals("independent credential", credential.read())
                // Restoring old ciphertext cannot be decrypted by the replacement key.
                val fresh = f.record.readBytes(); f.record.writeBytes(damagedRecord)
                assertEquals(LocalStoreFailure.Reason.BindingMalformed, f.bindings.inspectDamage()!!.reason)
                f.record.writeBytes(fresh)
            } finally { f.cleanup(); credential.deleteAndRetireKey() }
        }
    }
    @Test fun changedDamageOrNewHealthyBindingInvalidatesReviewBeforeAnyArchive() = runBlocking {
        val f = Fixture()
        try {
            f.bootstrap.open(f.user, f.device).close(); val database = f.file.readBytes()
            f.damage(false); val first = f.bootstrap.previewRecovery(f.user, f.device)
            f.record.appendBytes(byteArrayOf(3))
            rejected { f.bootstrap.recoverLocalStore(first) }
            assertArrayEquals(database, f.file.readBytes()); assertFalse(f.archives.exists())
            val second = f.bootstrap.previewRecovery(f.user, f.device)
            val replacement = LocalInstallationBinding.create()
            f.bindings.save(replacement)
            rejected { f.bootstrap.recoverLocalStore(second) }
            assertEquals(replacement, f.bindings.load()); assertArrayEquals(database, f.file.readBytes())
            assertFalse(f.archives.exists())
        } finally { f.cleanup() }
    }
    @Test fun repairWithNoDatabaseAndTemporaryFailureNeverDeletesOrCreatesAccountData() = runBlocking {
        val f = Fixture()
        try {
            f.bindings.save(LocalInstallationBinding.create()); f.damage(true)
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            assertEquals(0L, preview.summary.databaseBytes); assertTrue(preview.summary.rebuildsInstallationBinding)
            f.bootstrap.recoverLocalStore(preview)
            assertNotNull(f.bindings.load()); assertFalse(f.file.exists()); assertFalse(f.archives.exists())
            val bytes = f.record.readBytes()
            val unavailable = object: InstallationBindingRepairing by f.bindings {
                override suspend fun load(): LocalInstallationBinding? = throw LocalStoreFailure(LocalStoreFailure.Reason.BindingUnavailable)
                override suspend fun inspectDamage(): InstallationBindingDamage? = error("temporary failure must not be inspected for repair")
            }
            rejected { LocalStoreBootstrapper(context, unavailable).previewRecovery(f.user, f.device) }
            assertArrayEquals(bytes, f.record.readBytes()); assertFalse(f.file.exists())
        } finally { f.cleanup() }
    }
    @Test fun anotherAccountsOpenHandleBlocksGlobalKeyReplacementAndItsFilesAreNeverMoved() = runBlocking {
        val f = Fixture(); val other = UserId(UUID.randomUUID().toString()); val otherFile = accountDatabaseFile(context, other, f.device)
        try {
            f.bootstrap.open(f.user, f.device).close()
            val opened = f.bootstrap.open(other, f.device)
            try {
                f.damage(false); val bytes = f.record.readBytes()
                val preview = f.bootstrap.previewRecovery(f.user, f.device)
                rejected { f.bootstrap.recoverLocalStore(preview) }
                assertArrayEquals(bytes, f.record.readBytes()); assertFalse(f.archives.exists())
            } finally { opened.close() }
            val retained = otherFile.readBytes()
            f.bootstrap.recoverLocalStore(f.bootstrap.previewRecovery(f.user, f.device))
            assertArrayEquals(retained, otherFile.readBytes())
            rejected { f.bootstrap.open(other, f.device).close() }
            f.bootstrap.open(f.user, f.device).close()
        } finally { f.cleanup(); SQLiteDatabase.deleteDatabase(otherFile) }
    }
    @Test fun interruptedArchiveAfterKeyRepairResumesWithoutReusingTheDamagedKey() = runBlocking {
        val f = Fixture()
        try {
            f.bootstrap.open(f.user, f.device).close(); val bytes = f.file.readBytes(); f.damage(true)
            f.resources.mkdir(); File(f.resources, "attachment.txt").writeText("retained")
            val engine = LocalStoreRecoveryEngine(context, f.bindings, { 0L }) {
                if (it == RecoveryArtifactKind.Database) throw IOException("injected interruption")
            }
            try { engine.recover(engine.preview(f.user, f.device)); fail("expected interruption") } catch (_: IOException) {}
            val repaired = f.bindings.load(); assertNotNull(repaired); assertTrue(LocalStoreRecoveryEngine.pending(f.file))
            f.bootstrap.open(f.user, f.device).close()
            assertEquals(repaired, f.bindings.load()); assertFalse(LocalStoreRecoveryEngine.pending(f.file))
            val archive = f.archives.listFiles()!!.single()
            assertArrayEquals(bytes, File(archive, "Database").readBytes())
            assertEquals("retained", File(archive, "Resources/attachment.txt").readText())
        } finally { f.cleanup() }
    }
    @Test fun failedReplacementBeforeJournalLeavesOriginalFilesForAnotherExplicitReview() = runBlocking {
        val f = Fixture()
        try {
            f.bootstrap.open(f.user, f.device).close(); val bytes = f.file.readBytes(); f.damage(true)
            val interrupted = object: InstallationBindingRepairing by f.bindings {
                override suspend fun replaceDamagedBinding(expected: InstallationBindingDamage, replacement: LocalInstallationBinding) {
                    f.bindings.replaceDamagedBinding(expected, replacement)
                    throw IOException("after key repair before archive journal")
                }
            }
            val bootstrap = LocalStoreBootstrapper(context, interrupted)
            rejected { bootstrap.recoverLocalStore(bootstrap.previewRecovery(f.user, f.device)) }
            assertArrayEquals(bytes, f.file.readBytes()); assertFalse(LocalStoreRecoveryEngine.pending(f.file)); assertFalse(f.archives.exists())
            f.bootstrap.recoverLocalStore(f.bootstrap.previewRecovery(f.user, f.device))
            f.bootstrap.open(f.user, f.device).close()
            assertArrayEquals(bytes, File(f.archives.listFiles()!!.single(), "Database").readBytes())
        } finally { f.cleanup() }
    }
    @Test fun orphanFirstWriteIsNotTreatedAsAnEmptyInstallationAndExplicitRepairRemovesAllArtifacts() = runBlocking {
        val f = Fixture()
        try {
            f.bindings.save(LocalInstallationBinding.create())
            assertTrue(f.record.renameTo(File(f.record.path + ".new"))); f.keys.deleteEntry(f.alias)
            rejected { f.bootstrap.open(f.user, f.device).close() }
            assertFalse(f.file.exists()); assertFalse(f.keys.containsAlias(f.alias))
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            assertTrue(preview.summary.rebuildsInstallationBinding)
            f.bootstrap.recoverLocalStore(preview)
            assertNotNull(f.bindings.load()); assertFalse(File(f.record.path + ".new").exists())
            f.bootstrap.open(f.user, f.device).close()
        } finally { f.cleanup() }
    }

}
