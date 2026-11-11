package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.UUID

class InterruptedBindingRecoveryTests {
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
        val journal = File(file.path + ".recovery.json")
        val folder get() = archives.listFiles()!!.single()
        val keys get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "com.xmtx.im.$name.v1"
        var original = byteArrayOf()
        suspend fun interrupt(after: RecoveryArtifactKind = RecoveryArtifactKind.Database) {
            SqliteClientStore(context, user, device).close()
            original = file.readBytes()
            resources.mkdir(); File(resources, "owner.lock").writeText(""); File(resources, "attachment.txt").writeText("retained attachment")
            val engine = LocalStoreRecoveryEngine(context, bindings, { 0L }) {
                if (it == after) throw IOException("injected archive interruption")
            }
            try { engine.recover(engine.preview(user, device)); fail("expected interruption") } catch (_: IOException) {}
            assertTrue(LocalStoreRecoveryEngine.pending(file))
        }
        fun damage(missingKey: Boolean) {
            if (missingKey) keys.deleteEntry(alias)
            else { val bytes = record.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte(); record.writeBytes(bytes) }
        }
        fun assertCompleted(originalFolder: String) {
            assertEquals(originalFolder, folder.name); assertEquals(1, archives.listFiles()!!.size)
            assertArrayEquals(original, File(folder, "Database").readBytes())
            assertEquals("retained attachment", File(folder, "Resources/attachment.txt").readText())
            assertTrue(File(folder, "manifest.json").isFile); assertFalse(LocalStoreRecoveryEngine.pending(file))
        }
        fun cleanup() {
            SQLiteDatabase.deleteDatabase(file)
            for (suffix in listOf("", ".bak", ".new")) { File(record.path + suffix).delete(); File(journal.path + suffix).delete() }
            resources.deleteRecursively(); archives.deleteRecursively(); keys.deleteEntry(alias)
        }
    }
    private suspend fun rejected(body: suspend () -> Unit) {
        try { body(); fail("unexpected recovery") } catch (_: LocalStoreFailure) {}
    }
    @Test fun damagedBindingAfterPartialOrCompleteArchiveCanBeReviewedAndContinuedInTheSameFolder() = runBlocking {
        for (kind in listOf(RecoveryArtifactKind.Database, RecoveryArtifactKind.Resources)) {
            for (missingKey in listOf(false, true)) {
                val f = Fixture()
                try {
                    f.interrupt(kind); val folder = f.folder.name; val journal = f.journal.readBytes(); val old = f.bindings.load()
                    f.damage(missingKey); val damaged = f.record.readBytes()
                    rejected { f.bootstrap.open(f.user, f.device).close() }
                    val preview = f.bootstrap.previewRecovery(f.user, f.device)
                    assertTrue(preview.summary.continuesRecovery); assertTrue(preview.summary.rebuildsInstallationBinding)
                    assertTrue(preview.summary.includesResources); assertEquals(f.original.size.toLong(), preview.summary.databaseBytes)
                    assertArrayEquals(journal, f.journal.readBytes()); assertArrayEquals(damaged, f.record.readBytes())
                    f.bootstrap.recoverLocalStore(preview)
                    assertNotEquals(old, f.bindings.load()); f.assertCompleted(folder)
                    f.bootstrap.open(f.user, f.device).use { assertTrue(it.snapshot().messages.isEmpty()) }
                } finally { f.cleanup() }
            }
        }
    }
    @Test fun missingOrAlreadyReplacedBindingNeedsNewReviewAndNeverCreatesASecondArchive() = runBlocking {
        for (missing in listOf(false, true)) {
            val f = Fixture()
            try {
                f.interrupt(); val folder = f.folder.name
                if (missing) f.bindings.delete() else f.bindings.save(LocalInstallationBinding.create())
                val before = f.bindings.load()
                rejected { f.bootstrap.open(f.user, f.device).close() }
                val preview = f.bootstrap.previewRecovery(f.user, f.device)
                assertTrue(preview.summary.continuesRecovery); assertEquals(missing, preview.summary.rebuildsInstallationBinding)
                f.bootstrap.recoverLocalStore(preview); f.assertCompleted(folder)
                if (before != null) assertEquals(before, f.bindings.load()) else assertNotNull(f.bindings.load())
                f.bootstrap.open(f.user, f.device).close()
            } finally { f.cleanup() }
        }
    }
    @Test fun failureAfterReplacementButBeforeJournalUpdateCanBeReviewedAgainWithoutAnotherKeyRotation() = runBlocking {
        val f = Fixture()
        try {
            f.interrupt(); val folder = f.folder.name; val journal = f.journal.readBytes(); f.damage(true)
            val interrupted = object: InstallationBindingRepairing by f.bindings {
                override suspend fun replaceDamagedBinding(expected: InstallationBindingDamage, replacement: LocalInstallationBinding) {
                    f.bindings.replaceDamagedBinding(expected, replacement); throw IOException("before rebinding journal")
                }
            }
            val first = LocalStoreBootstrapper(context, interrupted)
            rejected { first.recoverLocalStore(first.previewRecovery(f.user, f.device)) }
            val replacement = f.bindings.load(); assertNotNull(replacement)
            assertArrayEquals(journal, f.journal.readBytes()); assertTrue(f.resources.isDirectory)
            rejected { f.bootstrap.open(f.user, f.device).close() }
            val second = f.bootstrap.previewRecovery(f.user, f.device)
            assertFalse(second.summary.rebuildsInstallationBinding)
            f.bootstrap.recoverLocalStore(second)
            assertEquals(replacement, f.bindings.load()); f.assertCompleted(folder)
        } finally { f.cleanup() }
    }
    @Test fun failureAfterJournalRebindResumesAutomaticallyUsingTheReviewedPlan() = runBlocking {
        val f = Fixture()
        try {
            f.interrupt(); val folder = f.folder.name; f.damage(false)
            val engine = LocalStoreRecoveryEngine(context, f.bindings, { 0L }) {
                if (it == RecoveryArtifactKind.Resources) throw IOException("after second archive rename")
            }
            try { engine.recover(engine.preview(f.user, f.device)); fail("expected interruption") } catch (_: IOException) {}
            val rebound = f.bindings.load(); assertNotNull(rebound); assertTrue(LocalStoreRecoveryEngine.pending(f.file))
            LocalStoreBootstrapper(context, f.bindings).open(f.user, f.device).close()
            assertEquals(rebound, f.bindings.load()); f.assertCompleted(folder)
        } finally { f.cleanup() }
    }
    @Test fun changedJournalBindingAndDuplicateSourceInvalidateReviewWithoutMovingOrDeletingEvidence() = runBlocking {
        val f = Fixture()
        try {
            f.interrupt(); f.damage(true)
            val reviewed = f.bootstrap.previewRecovery(f.user, f.device)
            val originalJournal = f.journal.readText(); val damaged = f.record.readBytes()
            f.journal.writeText(originalJournal.replace("\"operation\":\"${f.folder.name}\"", "\"operation\":\"${UUID.randomUUID().toString().uppercase()}\""))
            rejected { f.bootstrap.recoverLocalStore(reviewed) }
            assertArrayEquals(damaged, f.record.readBytes()); assertTrue(f.resources.exists())
            f.journal.writeText(originalJournal)
            val second = f.bootstrap.previewRecovery(f.user, f.device)
            f.bindings.replaceDamagedBinding(requireNotNull(f.bindings.inspectDamage()), LocalInstallationBinding.create()) // Another explicit repair completed after review.
            rejected { f.bootstrap.recoverLocalStore(second) }
            val third = f.bootstrap.previewRecovery(f.user, f.device)
            f.file.writeBytes(f.original) // Same bytes at both locations are still ambiguous.
            rejected { f.bootstrap.recoverLocalStore(third) }
            assertArrayEquals(f.original, f.file.readBytes()); assertArrayEquals(f.original, File(f.folder, "Database").readBytes())
            assertTrue(f.resources.exists()); assertFalse(File(f.folder, "manifest.json").exists())
        } finally { f.cleanup() }
    }
    @Test fun symlinkedArchiveOrJournalTemporaryFileCannotRedirectReviewOrReplacement() = runBlocking {
        val f = Fixture(); val elsewhere = File(context.cacheDir, "interrupted-recovery-${UUID.randomUUID()}")
        try {
            f.interrupt(); f.damage(false); val damaged = f.record.readBytes()
            val folder = f.folder
            assertTrue(folder.renameTo(elsewhere))
            Os.symlink(elsewhere.path, folder.path)
            rejected { f.bootstrap.previewRecovery(f.user, f.device) }
            assertArrayEquals(damaged, f.record.readBytes()); assertTrue(File(elsewhere, "Database").isFile)
            folder.delete(); assertTrue(elsewhere.renameTo(folder))
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            elsewhere.mkdir(); val keep = File(elsewhere, "keep"); keep.writeText("unchanged")
            Os.symlink(keep.path, f.journal.path + ".new")
            rejected { f.bootstrap.recoverLocalStore(preview) }
            assertEquals("unchanged", keep.readText()); assertArrayEquals(damaged, f.record.readBytes())
        } finally { File(f.journal.path + ".new").delete(); f.cleanup(); elsewhere.deleteRecursively() }
    }
    @Test fun expiredForeignAndUnavailableReviewsNeverChangeAnInterruptedArchive() = runBlocking {
        val f = Fixture()
        try {
            f.interrupt(); f.damage(true); val damaged = f.record.readBytes(); val journal = f.journal.readBytes()
            var now = 0L
            val owner = LocalStoreBootstrapper(context, f.bindings) { now }
            val expired = owner.previewRecovery(f.user, f.device); now = 60_000_000_000
            rejected { owner.recoverLocalStore(expired) }
            val foreign = owner.previewRecovery(f.user, f.device)
            rejected { f.bootstrap.recoverLocalStore(foreign) }
            val unavailable = object: InstallationBindingRepairing by f.bindings {
                override suspend fun load(): LocalInstallationBinding? = throw LocalStoreFailure(LocalStoreFailure.Reason.BindingUnavailable)
            }
            rejected { LocalStoreBootstrapper(context, unavailable).previewRecovery(f.user, f.device) }
            assertArrayEquals(damaged, f.record.readBytes()); assertArrayEquals(journal, f.journal.readBytes()); assertTrue(f.resources.exists())
        } finally { f.cleanup() }
    }
    @Test fun alteredArchivedContentMissingArtifactUnexpectedSidecarAndWrongAccountCannotBeReviewed() = runBlocking {
        for (variant in 0..3) {
            val f = Fixture()
            try {
                f.interrupt(); f.damage(true); val damaged = f.record.readBytes()
                when (variant) {
                    0 -> File(f.folder, "Database").appendText("changed")
                    1 -> f.resources.deleteRecursively()
                    2 -> File(f.file.path + "-wal").writeText("unexpected sidecar")
                    3 -> f.journal.writeText(f.journal.readText().replace(f.user.value, UUID.randomUUID().toString()))
                }
                rejected { f.bootstrap.previewRecovery(f.user, f.device) }
                assertArrayEquals(damaged, f.record.readBytes()); assertFalse(File(f.folder, "manifest.json").exists())
            } finally { f.cleanup() }
        }
    }

    @Test fun relocatedResourceNeedsFreshReviewAndAnArchivedOwnerLockStillBlocksRecovery() = runBlocking {
        val f = Fixture()
        try {
            f.interrupt(); f.damage(false); val damaged = f.record.readBytes()
            val preview = f.bootstrap.previewRecovery(f.user, f.device)
            val retained = File(f.folder, "Resources")
            assertTrue(f.resources.renameTo(retained))
            rejected { f.bootstrap.recoverLocalStore(preview) }
            assertArrayEquals(damaged, f.record.readBytes())
            java.io.RandomAccessFile(File(retained, "owner.lock"), "rw").use { handle ->
                handle.channel.lock().use { rejected { f.bootstrap.previewRecovery(f.user, f.device) } }
            }
            assertArrayEquals(damaged, f.record.readBytes())
            val folder = f.folder.name
            f.bootstrap.recoverLocalStore(f.bootstrap.previewRecovery(f.user, f.device))
            f.assertCompleted(folder)
        } finally { f.cleanup() }
    }

}
