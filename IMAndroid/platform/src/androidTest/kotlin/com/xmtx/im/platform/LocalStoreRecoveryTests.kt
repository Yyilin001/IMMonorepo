package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID

class LocalStoreRecoveryTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private class Bindings : InstallationBindingStore {
        var value: LocalInstallationBinding? = null
        var failure: LocalStoreFailure? = null
        override suspend fun load(): LocalInstallationBinding? { failure?.let { throw it }; return value }
        override suspend fun save(binding: LocalInstallationBinding) { value = binding }
        override suspend fun delete() { value = null }
    }
    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val bindings = Bindings(); var now = 0L
        val bootstrap = LocalStoreBootstrapper(context, bindings) { now }
        val file = accountDatabaseFile(context, user, device)
        val scope = file.name.removePrefix("im-").removeSuffix(".db")
        val resources = File(context.noBackupFilesDir.canonicalFile, "resources-$scope")
        val archives = File(context.noBackupFilesDir, "local-recovery/$scope")
        fun legacy() { SqliteClientStore(context, user, device).close() }
        fun media() { resources.mkdir(); File(resources, "owner.lock").writeText(""); File(resources, "attachment.txt").writeText("original attachment") }
        fun cleanup() { SQLiteDatabase.deleteDatabase(file); File("${file.path}.recovery.json").delete();
            File("${file.path}.recovery.json.bak").delete(); resources.deleteRecursively(); archives.deleteRecursively() }
    }
    private suspend fun rejected(action: suspend () -> Unit) {
        try { action(); fail("untrusted recovery succeeded") } catch (_: LocalStoreFailure) {}
    }

    @Test fun explicitRecoveryPreservesOriginalDatabaseAndResourcesAndCreatesFreshBoundState() = runBlocking {
        val f = Fixture()
        try {
            val oldIdentity = SqliteClientStore(context, f.user, f.device).use { it.databaseIdentity }
            f.media(); val bytes = f.file.readBytes()
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            assertEquals(bytes.size.toLong(), preview.summary.databaseBytes); assertTrue(preview.summary.includesResources)
            assertArrayEquals(bytes, f.file.readBytes()); assertFalse(f.archives.exists())
            f.bootstrap.recoverLocalStore(preview)
            val archive = f.archives.listFiles()!!.single()
            assertArrayEquals(bytes, File(archive, "Database").readBytes())
            assertEquals("original attachment", File(archive, "Resources/attachment.txt").readText())
            assertTrue(File(archive, "manifest.json").isFile)
            assertFalse(f.file.exists()); assertFalse(f.resources.exists())
            val newIdentity = f.bootstrap.open(f.user, f.device).use {
                assertTrue(it.snapshot().messages.isEmpty()); assertNotEquals(oldIdentity, it.databaseIdentity); it.databaseIdentity
            }
            f.bootstrap.open(f.user, f.device).use { assertEquals(newIdentity, it.databaseIdentity) }
            assertEquals(f.bindings.value, f.bootstrap.verifyExistingBinding(f.user, f.device))
            rejected { f.bootstrap.recoverLocalStore(preview) }
            assertEquals(1, f.archives.listFiles()!!.size)
        } finally { f.cleanup() }
    }

    @Test fun interruptedArchiveResumesFromItsDurableJournalBeforeAnyDatabaseCanOpen() = runBlocking {
        val f = Fixture()
        try {
            f.legacy(); f.media(); val bytes = f.file.readBytes()
            val engine = LocalStoreRecoveryEngine(context, f.bindings, { 0L }) { kind ->
                if (kind == RecoveryArtifactKind.Database) throw IOException("injected process boundary")
            }
            val preview = engine.preview(f.user, f.device)
            try { engine.recover(preview); fail("injected failure missing") } catch (_: IOException) {}
            assertTrue(LocalStoreRecoveryEngine.pending(f.file)); assertFalse(f.file.exists()); assertTrue(f.resources.exists())
            rejected { SqliteClientStore(context, f.user, f.device).close() }
            rejected { f.bootstrap.verifyExistingBinding(f.user, f.device) }
            LocalStoreBootstrapper(context, f.bindings).open(f.user, f.device).close()
            assertFalse(LocalStoreRecoveryEngine.pending(f.file))
            val archive = f.archives.listFiles()!!.single()
            assertArrayEquals(bytes, File(archive, "Database").readBytes())
            assertEquals("original attachment", File(archive, "Resources/attachment.txt").readText())
            assertTrue(File(archive, "manifest.json").isFile)
            f.bootstrap.open(f.user, f.device).close()
            assertEquals(1, f.archives.listFiles()!!.size)
        } finally { f.cleanup() }
    }

    @Test fun staleForeignAndChangedReviewsCannotMoveFiles() = runBlocking {
        val f = Fixture()
        try {
            f.legacy(); val bytes = f.file.readBytes()
            val expired = f.bootstrap.previewRecovery(f.user, f.device)
            f.now = 60_000_000_000
            rejected { f.bootstrap.recoverLocalStore(expired) }
            val foreign = f.bootstrap.previewRecovery(f.user, f.device)
            rejected { LocalStoreBootstrapper(context, f.bindings).recoverLocalStore(foreign) }
            f.file.appendText("changed after review")
            val changed = f.file.readBytes()
            rejected { f.bootstrap.recoverLocalStore(foreign) }
            assertArrayEquals(changed, f.file.readBytes()); assertFalse(f.archives.exists()); assertNull(f.bindings.value)
            f.file.writeBytes(bytes)
        } finally { f.cleanup() }
    }

    @Test fun activeDatabaseAndMediaOwnersBlockRecoveryUntilTheirActualHandlesClose() = runBlocking {
        val f = Fixture()
        try {
            f.legacy(); f.media()
            SqliteClientStore(context, f.user, f.device).use { rejected { f.bootstrap.previewRecovery(f.user, f.device) } }
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            SqliteClientStore(context, f.user, f.device).use { rejected { f.bootstrap.recoverLocalStore(preview) } }
            RandomAccessFile(File(f.resources, "owner.lock"), "rw").use { file -> file.channel.lock().use {
                rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            } }
            assertFalse(f.archives.exists())
            f.bootstrap.recoverLocalStore(f.bootstrap.previewRecovery(f.user, f.device))
            f.bootstrap.open(f.user, f.device).close()
        } finally { f.cleanup() }
    }

    @Test fun healthyStoresAndUnavailableBindingAreNeverReset() = runBlocking {
        val f = Fixture()
        try {
            f.bootstrap.open(f.user, f.device).close()
            val bytes = f.file.readBytes()
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            f.bindings.failure = LocalStoreFailure(LocalStoreFailure.Reason.BindingUnavailable)
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            assertArrayEquals(bytes, f.file.readBytes()); assertFalse(f.archives.exists())
        } finally { f.cleanup() }
    }

    @Test fun unreadableBoundSchemaRequiresFreshConstructorFailureEvidenceBeforeRecovery() = runBlocking {
        val f = Fixture()
        try {
            f.bootstrap.open(f.user, f.device).close()
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("DROP TABLE messages"); db.execSQL("CREATE VIEW messages AS SELECT 1 AS id")
            }
            // Matching ownership alone must not make a healthy-store reset available.
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            rejected { f.bootstrap.open(f.user, f.device).close() }
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            assertTrue(preview.summary.databaseBytes > 0)
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { it.execSQL("CREATE TABLE changed_after_failure(value TEXT)") }
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            rejected { f.bootstrap.open(f.user, f.device).close() }
            f.bootstrap.recoverLocalStore(f.bootstrap.previewRecovery(f.user, f.device))
            f.bootstrap.open(f.user, f.device).use { assertTrue(it.snapshot().messages.isEmpty()) }
            assertEquals(1, f.archives.listFiles()!!.size)
        } finally { f.cleanup() }
    }

    @Test fun replacementAtAnInterruptedSourceCannotBeOverwrittenOrAdopted() = runBlocking {
        val f = Fixture()
        try {
            f.legacy(); f.media(); val bytes = f.file.readBytes()
            val engine = LocalStoreRecoveryEngine(context, f.bindings, { 0L }) { throw IOException("interrupt") }
            try { engine.recover(engine.preview(f.user, f.device)) } catch (_: IOException) {}
            f.file.writeText("replacement must remain untouched")
            rejected { f.bootstrap.open(f.user, f.device).close() }
            assertEquals("replacement must remain untouched", f.file.readText())
            assertArrayEquals(bytes, File(f.archives.listFiles()!!.single(), "Database").readBytes())
            assertTrue(LocalStoreRecoveryEngine.pending(f.file))
        } finally { f.cleanup() }
    }

    @Test fun malformedRecoveryJournalCannotBeTreatedAsPermissionToCreateFreshState() = runBlocking {
        val f = Fixture()
        try {
            f.legacy(); val bytes = f.file.readBytes()
            val engine = LocalStoreRecoveryEngine(context, f.bindings, { 0L }) { throw IOException("interrupt") }
            try { engine.recover(engine.preview(f.user, f.device)) } catch (_: IOException) {}
            val journal = File("${f.file.path}.recovery.json")
            val original = journal.readText()
            journal.writeText(original.replace("\"format\":1", "\"format\":\"1\""))
            rejected { f.bootstrap.open(f.user, f.device).close() }
            assertFalse(f.file.exists()); assertTrue(LocalStoreRecoveryEngine.pending(f.file))
            assertArrayEquals(bytes, File(f.archives.listFiles()!!.single(), "Database").readBytes())
            journal.writeText(original)
            assertTrue(journal.renameTo(File("${journal.path}.bak")))
            f.bootstrap.open(f.user, f.device).close()
            assertFalse(LocalStoreRecoveryEngine.pending(f.file))
        } finally { f.cleanup() }
    }

    @Test fun resourceSymlinkCannotMoveAnotherDirectory() = runBlocking {
        val f = Fixture(); val outside = File(context.cacheDir, "recovery-outside-${UUID.randomUUID()}")
        try {
            f.legacy(); outside.mkdir(); File(outside, "keep").writeText("unchanged")
            android.system.Os.symlink(outside.path, f.resources.path)
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            assertEquals("unchanged", File(outside, "keep").readText()); assertFalse(f.archives.exists())
        } finally { f.resources.delete(); f.cleanup(); outside.deleteRecursively() }
    }

    @Test fun onlyTheRecoveredAccountsNativeUploadJournalIsCancelled() = runBlocking {
        val tests = ResourceSystemUploadTests()
        val first = tests.Fixture("https://localhost:1/upload")
        val other = tests.Fixture("https://localhost:1/upload")
        val mappings = mutableListOf<ResourceBackgroundUploadMapping>()
        var firstClosed = false; var otherClosed = false
        suspend fun install(f: ResourceSystemUploadTests.Fixture): ResourceBackgroundUploadMapping {
            val claim = f.prepare(); val registration = f.registrations(claim).single()
            val mapping = f.store.installBackgroundUploads(claim, kotlinx.collections.immutable.persistentListOf(registration), f.now).single()
            val now = android.os.SystemClock.elapsedRealtime()
            ResourceSystemUploadJournal.install(context, SystemUploadRecord(mapping, f.store.resourceScope, claim.work.request.checksum,
                registration.target.plan, ResourceSystemUploadDriver.boot(context), now, now + 60_000))
            mappings.add(mapping); return mapping
        }
        val firstScope = first.store.resourceScope; val otherScope = other.store.resourceScope
        try {
            val target = install(first); val untouched = install(other)
            first.close(); firstClosed = true; other.close(); otherClosed = true
            val bootstrap = LocalStoreBootstrapper(context, Bindings())
            bootstrap.recoverLocalStore(bootstrap.previewRecovery(first.actor, first.device))
            val rows = ResourceSystemUploadJournal.records(context)
            assertTrue(rows.first { it.mapping == target }.cancelled)
            assertNotNull(rows.first { it.mapping == target }.result)
            assertFalse(rows.first { it.mapping == untouched }.cancelled)
            assertNull(rows.first { it.mapping == untouched }.result)
        } finally {
            for (mapping in mappings) { ResourceSystemUploadDriver(context).cancelAndDrain(mapping); ResourceSystemUploadJournal.acknowledge(context, mapping) }
            if (!firstClosed) first.close(); if (!otherClosed) other.close()
            for ((user, device, scope) in listOf(Triple(first.actor, first.device, firstScope), Triple(other.actor, other.device, otherScope))) {
                SQLiteDatabase.deleteDatabase(accountDatabaseFile(context, user, device))
                File(context.noBackupFilesDir, "resources-$scope").deleteRecursively()
                File(context.noBackupFilesDir, "local-recovery/$scope").deleteRecursively()
            }
        }
    }
}
