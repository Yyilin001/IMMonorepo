package com.xmtx.im.platform

import android.app.job.JobScheduler
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

class NativeExitTransferTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val marker = FileLocalExitMarker(context, "native-exit-${UUID.randomUUID()}")
    private inner class Fixtures(url: String = "https://localhost:1/fixture") {
        val upload = ResourceSystemUploadTests().Fixture(url)
        val other = ResourceSystemUploadTests().Fixture(url)
        val download = ResourceSystemDownloadTests().Fixture(url)
        val uploads = mutableListOf<ResourceBackgroundUploadMapping>()
        suspend fun uploadRow(f: ResourceSystemUploadTests.Fixture = upload): SystemUploadRecord {
            val claim = f.prepare(); val registration = f.registrations(claim).single()
            val mapping = f.store.installBackgroundUploads(claim, persistentListOf(registration), f.now).single()
            uploads.add(mapping)
            val elapsed = SystemClock.elapsedRealtime()
            return SystemUploadRecord(mapping, f.store.resourceScope, claim.work.request.checksum, registration.target.plan,
                ResourceSystemUploadDriver.boot(context), elapsed, elapsed + 60_000, exitMarker = marker.identifier)
        }
        suspend fun downloadRow(): SystemDownloadRecord {
            download.install(); val elapsed = SystemClock.elapsedRealtime()
            return SystemDownloadRecord(download.mapping, download.store.resourceScope, download.target.target.plan,
                ResourceSystemUploadDriver.boot(context), elapsed, elapsed + 60_000, exitMarker = marker.identifier)
        }
        suspend fun close() {
            for (mapping in uploads) {
                ResourceSystemUploadDriver(context).cancelAndDrain(mapping)
                ResourceSystemUploadJournal.acknowledge(context, mapping)
            }
            upload.close(); other.close(); download.cleanup()
            for ((actor, device) in listOf(upload.actor to upload.device, other.actor to other.device, download.actor to download.device)) {
                val db = accountDatabaseFile(context, actor, device)
                File(context.noBackupFilesDir, "resources-${db.name.removePrefix("im-").removeSuffix(".db")}").deleteRecursively()
                SQLiteDatabase.deleteDatabase(db)
            }
            for (suffix in listOf("", ".bak", ".new")) File(marker.path.path + suffix).delete()
        }
    }
    private suspend fun force(task: String, upload: Boolean) {
        val id = if (upload) systemUploadJobId(task) else systemDownloadJobId(task)
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} $id").use {
            val output = android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText()
            assertTrue(output, output.contains("Running job"))
        }
    }

    @Test fun cleanupCancelsBothDirectionsByAccountWithoutTouchingAnotherAccount() = runBlocking {
        val f = Fixtures()
        try {
            val upload = f.uploadRow(); val untouched = f.uploadRow(f.other); val download = f.downloadRow()
            ResourceSystemUploadJournal.install(context, upload); ResourceSystemUploadJournal.install(context, untouched)
            ResourceSystemDownloadJournal.install(context, download)
            val cleanup = AccountNativeTransferCleanup(context)
            cleanup.drain(LocalExitAccount(f.upload.actor, f.upload.device))
            assertTrue(ResourceSystemUploadJournal.records(context).single { it.mapping == upload.mapping }.cancelled)
            assertNull(ResourceSystemDownloadJournal.records(context).single { it.mapping == download.mapping }.result)
            cleanup.drain(LocalExitAccount(f.download.actor, f.download.device))
            cleanup.drain(LocalExitAccount(f.upload.actor, f.upload.device))
            assertNotNull(ResourceSystemDownloadJournal.records(context).single { it.mapping == download.mapping }.result)
            val other = ResourceSystemUploadJournal.records(context).single { it.mapping == untouched.mapping }
            assertFalse(other.cancelled); assertNull(other.result)
        } finally { f.close() }
    }

    @Test fun persistedExitReferenceBlocksBothWorkerAdmissionsBeforeAnyAttempt() = runBlocking {
        val f = Fixtures()
        try {
            val upload = f.uploadRow(); val download = f.downloadRow()
            ResourceSystemUploadJournal.install(context, upload); ResourceSystemDownloadJournal.install(context, download)
            marker.markPending()
            assertNull(ResourceSystemUploadJournal.start(context, upload.mapping.task, upload.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()))
            assertNull(ResourceSystemDownloadJournal.start(context, download.mapping.task, download.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()))
            val up = ResourceSystemUploadJournal.records(context).single { it.mapping == upload.mapping }
            val down = ResourceSystemDownloadJournal.records(context).single { it.mapping == download.mapping }
            assertEquals(marker.identifier, up.exitMarker); assertEquals(marker.identifier, down.exitMarker)
            assertEquals(0, up.attempts); assertEquals(0, down.attempts)
            assertEquals(0L, up.result!!.sentBytes); assertEquals(0L, down.result!!.receivedBytes)
            assertNull(up.plan); assertNull(down.plan)
        } finally { f.close() }
    }
    @Test fun unreadableAccountIdentityDrainsOnlyTransfersBoundToItsExitMarker() = runBlocking {
        val f = Fixtures()
        try {
            val upload = f.uploadRow(); val download = f.downloadRow()
            val other = f.uploadRow(f.other).copy(exitMarker = "a".repeat(64))
            ResourceSystemUploadJournal.install(context, upload);ResourceSystemUploadJournal.install(context, other)
            ResourceSystemDownloadJournal.install(context, download);marker.markPending()
            AccountNativeTransferCleanup(context, exitMarker = marker).drain(null)
            assertNotNull(ResourceSystemUploadJournal.records(context).single {it.mapping == upload.mapping}.result)
            assertNotNull(ResourceSystemDownloadJournal.records(context).single {it.mapping == download.mapping}.result)
            val untouched = ResourceSystemUploadJournal.records(context).single {it.mapping == other.mapping}
            assertFalse(untouched.cancelled);assertNull(untouched.result)
        } finally { f.close() }
    }
    @Test fun unboundLegacyTransferCannotBeGuessedAsBelongingToUnreadableCredentials() = runBlocking {
        val f = Fixtures()
        try {
            val legacy = f.uploadRow().copy(exitMarker = null)
            ResourceSystemUploadJournal.install(context, legacy);marker.markPending()
            try { AccountNativeTransferCleanup(context, exitMarker = marker).drain(null);fail("guessed ownership") }
            catch (_: LocalExitFailure) {}
            assertTrue(marker.isPending());assertEquals(legacy,ResourceSystemUploadJournal.records(context).single {it.mapping == legacy.mapping})
            AccountNativeTransferCleanup(context).drain(LocalExitAccount(f.upload.actor,f.upload.device))
            AccountNativeTransferCleanup(context, exitMarker = marker).drain(null)
        } finally { f.close() }
    }

    @Test fun unreadableExitReferenceNeverStartsBytesButCleanupCanStillCancelTheJournal() = runBlocking {
        val f = Fixtures()
        try {
            val upload = f.uploadRow(); val download = f.downloadRow()
            ResourceSystemUploadJournal.install(context, upload); ResourceSystemDownloadJournal.install(context, download)
            marker.path.writeText("malformed marker")
            try { ResourceSystemUploadJournal.start(context, upload.mapping.task, upload.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()); fail("started") }
            catch (_: LocalExitFailure) {}
            try { ResourceSystemDownloadJournal.start(context, download.mapping.task, download.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()); fail("started") }
            catch (_: LocalExitFailure) {}
            assertEquals(0, ResourceSystemUploadJournal.records(context).single { it.mapping == upload.mapping }.attempts)
            val cleanup = AccountNativeTransferCleanup(context)
            cleanup.drain(LocalExitAccount(f.upload.actor, f.upload.device)); cleanup.drain(LocalExitAccount(f.download.actor, f.download.device))
            marker.clearPending()
            assertNull(ResourceSystemUploadJournal.start(context, upload.mapping.task, upload.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()))
            assertNull(ResourceSystemDownloadJournal.start(context, download.mapping.task, download.boot, SystemClock.elapsedRealtime(), System.currentTimeMillis()))
        } finally { f.close() }
    }

    @Test fun realJobServicesReadTheExitReferenceWithoutAnAccountOwner() = runBlocking {
        val f = Fixtures()
        try {
            val claim = f.upload.prepare(); val registration = f.upload.registrations(claim).single()
            val upload = f.upload.store.installBackgroundUploads(claim, persistentListOf(registration), f.upload.now).single(); f.uploads.add(upload)
            ResourceSystemUploadDriver(context, exitMarker = marker).schedule(f.upload.store, f.upload.files, upload, registration.target)
            f.download.install()
            val downloader = ResourceSystemDownloadDriver(context, exitMarker = marker)
            downloader.schedule(f.download.store, f.download.files, f.download.mapping, f.download.target)
            marker.markPending()
            force(upload.task, true); force(f.download.mapping.task, false)
            withTimeout(10_000) {
                while (ResourceSystemUploadJournal.records(context).single { it.mapping == upload }.result == null ||
                    ResourceSystemDownloadJournal.records(context).single { it.mapping == f.download.mapping }.result == null) delay(20)
            }
            assertEquals(0, ResourceSystemUploadJournal.records(context).single { it.mapping == upload }.attempts)
            assertEquals(0, ResourceSystemDownloadJournal.records(context).single { it.mapping == f.download.mapping }.attempts)
            AccountNativeTransferCleanup(context).drain(LocalExitAccount(f.upload.actor, f.upload.device))
            AccountNativeTransferCleanup(context).drain(LocalExitAccount(f.download.actor, f.download.device))
            assertNull(context.getSystemService(JobScheduler::class.java).getPendingJob(systemUploadJobId(upload.task)))
            assertNull(context.getSystemService(JobScheduler::class.java).getPendingJob(systemDownloadJobId(f.download.mapping.task)))
        } finally { f.close() }
    }

    @Test fun cleanupByExitMarkerDrainsAnActiveDownloadAndRetainsItsPartialByteEvidence() = runBlocking {
        val ca = File(context.noBackupFilesDir, "system-download-test-ca.pem"); val original = ca.takeIf { it.exists() }?.readBytes()
        val certificate = okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        ca.writeText(certificate.certificatePem())
        val keys = okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(certificate).build()
        try { okhttp3.mockwebserver.MockWebServer().use { server ->
            server.useHttps(keys.sslSocketFactory(), false); server.start()
            val f = Fixtures(server.url("/slow").toString())
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setBody(f.download.body).throttleBody(1, 1, TimeUnit.SECONDS))
                f.download.install()
                val driver = ResourceSystemDownloadDriver(context, TestResourceDownloadJobService::class.java, marker)
                driver.schedule(f.download.store, f.download.files, f.download.mapping, f.download.target)
                force(f.download.mapping.task, false); assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
                val key = SystemTransferProgressKey(f.download.store.resourceScope, ResourceTransferKind.Download, f.download.mapping.id, f.download.mapping.task)
                withTimeout(5000) { while ((systemTransferProgress.samples.value[key]?.transferredBytes ?: 0) == 0L) delay(10) }
                marker.markPending()
                AccountNativeTransferCleanup(context, downloads = driver, exitMarker = marker).drain(null)
                assertFalse(SystemDownloadFlights.contains(f.download.mapping.task))
                val receipt = ResourceSystemDownloadJournal.records(context).single { it.mapping == f.download.mapping }.result!!
                assertEquals(0L, receipt.receivedBytes); assertTrue(receipt.observation!!.cancelled)
                assertTrue(receipt.observation!!.bodyBytesReceived in 1 until f.download.body.length.toLong())
                assertTrue(f.download.store.resourceFiles().isEmpty())
            } finally { f.close() }
        } } finally { if (original == null) ca.delete() else ca.writeBytes(original) }
    }
}
