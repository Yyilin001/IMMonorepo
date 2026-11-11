package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class AccountSystemTransferAdmissionTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun cancellationDurationNeedsAnOwnedPermitAndCompletionIsRecordedOnlyOnce()=runBlocking<Unit> {
        var nanos=10L;val scheduler=AccountWorkScheduler();val admission=AccountSystemTransferAdmission(context,"0".repeat(64),scheduler,nanoTime={nanos})
        val mapping=id();val other=id();val observation=ResourceBackgroundTransferObservation(3,0,null,true,true)
        try {
            admission.beginCancellation(mapping);nanos=20
            admission.reserve(mapping,NetworkWorkKind.Upload,NetworkWorkPriority.Interactive,System.currentTimeMillis()+60000)
            admission.beginCancellation(mapping);nanos=30;admission.beginCancellation(mapping);nanos=50
            admission.release(mapping,observation=observation);admission.release(mapping,observation=observation)
            var samples=scheduler.transferDiagnostics.snapshot().backgrounds;assertEquals(1,samples.size)
            assertEquals(30L,samples.single().cancellationToPermitReleaseNanos);assertEquals(3L,samples.single().bodyBytesSent)
            admission.beginCancellation(other);admission.release(other);assertEquals(1L,scheduler.transferDiagnostics.snapshot().backgroundRecorded)
            admission.reserve(other,NetworkWorkKind.Download,NetworkWorkPriority.Interactive,System.currentTimeMillis()+60000)
            admission.release(other);samples=scheduler.transferDiagnostics.snapshot().backgrounds
            assertEquals(2,samples.size);assertFalse(samples.last().completionObserved);assertNull(samples.last().bodyBytesReceived);assertNull(samples.last().cancellationToPermitReleaseNanos)
        } finally {admission.release(mapping);admission.release(other);scheduler.closeAndDrain()}
    }
    @Test fun nativeMappingsChargeDomainRetriesToTheSameAccountMediaBucket()=runBlocking<Unit> {
        val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
        val admission=AccountSystemTransferAdmission(context,"0".repeat(64),scheduler);val nextId=id();val initialId=id()
        try {
            repeat(5) {val mapping=id()
                withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {
                    admission.reserve(mapping,NetworkWorkKind.Upload,NetworkWorkPriority.Recovery,System.currentTimeMillis()+60000)
                };admission.release(mapping)
            }
            val next=async(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {
                admission.reserve(nextId,NetworkWorkKind.Upload,NetworkWorkPriority.Recovery,System.currentTimeMillis()+60000)
            }
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            withContext(NetworkWorkIntent(NetworkWorkPriority.Interactive,false)) {
                admission.reserve(initialId,NetworkWorkKind.Download,NetworkWorkPriority.Interactive,System.currentTimeMillis()+60000)
            }
            assertFalse(next.isCompleted);assertEquals(1,scheduler.snapshot().activeDownloads);admission.release(initialId)
            clock.set(2000);scheduler.setDegraded(false);withTimeout(5000) {next.await()};assertEquals(1,scheduler.snapshot().activeUploads)
        } finally {admission.release(nextId);admission.release(initialId);scheduler.closeAndDrain()}
    }
    @Test fun jobAlreadyOnWireIsAdoptedBeforeForegroundAndReceiptReleasesOnlyPhysicalQuota()=runBlocking<Unit> {
        val cert=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        java.io.File(context.noBackupFilesDir,"system-download-test-ca.pem").writeText(cert.certificatePem())
        val keys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(cert).build()
        val server=okhttp3.mockwebserver.MockWebServer();server.useHttps(keys.sslSocketFactory(),false);server.start()
        val f=ResourceSystemDownloadTests().Fixture(server.url("/adopt-running").toString())
        val gate=java.util.concurrent.CountDownLatch(1)
        server.dispatcher=object:okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request:okhttp3.mockwebserver.RecordedRequest):okhttp3.mockwebserver.MockResponse {
                check(gate.await(15,java.util.concurrent.TimeUnit.SECONDS));return okhttp3.mockwebserver.MockResponse().setBody(f.body).throttleBody(1,100,java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,downloadTransferLimit=1,interactiveByteReserve=0))
        val control=object:ResourceUploadControl {
            override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("No upload")
            override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("No upload")
            override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("No upload")
            override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
            override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
        }
        var activity:AccountResourceActivity?=null;var run:Job?=null;var next:Job?=null
        try {
            // The worker starts from the persisted request without an account scheduler/owner.
            f.schedule();ResourceSystemDownloadTests().force(f.mapping.task)
            assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)})
            f.files.close()
            val owner=AccountResourceActivity(context,f.store,control,systemDownloads=f.driver,scheduler=scheduler);activity=owner
            owner.prepareNetworkTransfers();assertEquals(1,scheduler.snapshot().activeDownloads)
            run=launch {owner.runForeground()}
            val entered=CompletableDeferred<Unit>()
            next=launch {scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download)) {entered.complete(Unit)}}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            assertFalse(entered.isCompleted);assertEquals(1,server.requestCount)
            gate.countDown()
            val transfer=ResourceTransferId(ResourceTransferKind.Download,f.mapping.download)
            val sample=withTimeout(5000) {owner.transferWaiting.snapshots.first {it.attempts[transfer]?.transferredBytes in 1L until f.body.length.toLong()}}.attempts[transfer]!!
            assertEquals(f.mapping.id,sample.attemptId);assertEquals(f.body.length.toLong(),sample.expectedBytes)
            assertFalse(f.store.resourceDownloads().single().work.terminal);assertTrue(f.store.resourceFiles().isEmpty())
            withTimeout(10000) {entered.await();next.join()}
            assertTrue(owner.transferWaiting.snapshots.value.attempts.isEmpty())
            withTimeout(5000) {while(f.store.activeBackgroundDownloads().none {it.received}) delay(5)}
            assertEquals(0,scheduler.snapshot().activeDownloads)
            val metric=scheduler.transferDiagnostics.snapshot().backgrounds.single()
            assertTrue(metric.completionObserved);assertEquals(f.body.length.toLong(),metric.bodyBytesReceived)
            assertEquals(false,metric.cancelled);assertNull(metric.cancellationToPermitReleaseNanos)
            // No fresh account grant was supplied: raw received bytes are still not published business data.
            assertFalse(f.store.resourceDownloads().single().work.terminal);assertTrue(f.store.resourceFiles().isEmpty())
        } finally {gate.countDown();next?.cancelAndJoin();run?.cancelAndJoin();activity?.close();scheduler.closeAndDrain();f.cleanup();server.close()}
    }
    @Test fun queuedAutomaticMappingPromotesWithoutChangingIdentityOrDuplicatingItsPermit()=runBlocking<Unit> {
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=2,downloadTransferLimit=2,interactiveByteReserve=1))
        val admission=AccountSystemTransferAdmission(context,"0".repeat(64),scheduler)
        val held=scheduler.acquire(NetworkWorkContext("mediaProvider",NetworkWorkPriority.Background,NetworkWorkKind.Download))
        val mapping=id()
        try {
            val pending=async {admission.reserve(mapping,NetworkWorkKind.Download,NetworkWorkPriority.Background,System.currentTimeMillis()+60000)}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            admission.promote(mapping,NetworkWorkPriority.Interactive);withTimeout(5000) {pending.await()}
            assertEquals(2,scheduler.snapshot().activeDownloads);assertEquals(1,scheduler.snapshot().activeBackgroundTransfers)
            admission.promote(mapping,NetworkWorkPriority.Background)
            assertEquals(1,scheduler.snapshot().activeBackgroundTransfers)
        } finally {admission.release(mapping);scheduler.release(held);scheduler.closeAndDrain()}
    }
    @Test fun nativeReceiptCooldownBlocksMediaButLeavesOtherServicesAvailable()=runBlocking<Unit> {
        val now=java.util.concurrent.atomic.AtomicLong(1000)
        val scheduler=AccountWorkScheduler(nowMillis=now::get)
        val admission=AccountSystemTransferAdmission(context,"0".repeat(64),scheduler);val mapping=id()
        try {
            admission.reserve(mapping,NetworkWorkKind.Upload,NetworkWorkPriority.Recovery,System.currentTimeMillis()+60000)
            admission.release(mapping,503,System.currentTimeMillis()+600_000)
            val next=async {scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download)) {}}
            withTimeout(5000) {while(scheduler.snapshot().waiting!=1) delay(5)}
            scheduler.withPermit(NetworkWorkContext("account")) {assertEquals(1,scheduler.snapshot().active)}
            now.addAndGet(300_001);scheduler.setDegraded(false)
            assertEquals(1,scheduler.snapshot().waiting);assertFalse(next.isCompleted)
            now.addAndGet(300_001);scheduler.setDegraded(false);withTimeout(5000) {next.await()}
        } finally {admission.release(mapping);scheduler.closeAndDrain()}
    }
    @Test fun multipartBatchQueuesEachPhysicalJobAndCompletionAdmitsTheNextSibling()=runBlocking<Unit> {
        val cert=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        java.io.File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeText(cert.certificatePem())
        val keys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(cert).build()
        val server=okhttp3.mockwebserver.MockWebServer();server.useHttps(keys.sslSocketFactory(),false);server.start()
        val f=ResourceSystemUploadTests().Fixture(server.url("/part").toString())
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(uploadTransferLimit=1))
        val admission=AccountSystemTransferAdmission(context,f.store.resourceScope,scheduler)
        val driver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        var coordinator:AccountSystemUploads?=null;var observer:Job?=null
        suspend fun force(mapping:ResourceBackgroundUploadMapping) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(mapping.task)}").use {
                val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText();assertTrue(output,output.contains("Running job"))
            }
        }
        try {
            val claim=f.prepare();val targets=f.registrations(claim,true).map {it.target}.toPersistentList()
            val control=object:ResourceBackgroundUploadControl {
                override suspend fun backgroundTargets(session:ResourceUploadSession,request:ResourceUploadRequest,parts:PersistentList<Int>)=targets
            }
            val owner=AccountSystemUploads(context,f.store,f.files,control,driver,admission);coordinator=owner
            admission.prepare();owner.enable();observer=launch {owner.observe()}
            repeat(2) {server.enqueue(okhttp3.mockwebserver.MockResponse().setResponseCode(204))}
            val delegated=async {owner.delegate(claim)}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            val first=ResourceSystemUploadJournal.records(context).single {it.scope==f.store.resourceScope}.mapping
            assertEquals(2,f.store.activeBackgroundUploads().size);assertEquals(1,scheduler.snapshot().activeUploads)
            force(first);assertTrue(withTimeout(10000) {delegated.await()})
            val second=f.store.activeBackgroundUploads().single();assertNotEquals(first.id,second.id)
            assertEquals(1,scheduler.snapshot().activeUploads);force(second)
            withTimeout(10000) {while(f.store.activeBackgroundUploads().isNotEmpty()) delay(5)}
            assertEquals(0,scheduler.snapshot().activeUploads);assertEquals(2,server.requestCount)
            assertEquals("01234",server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)!!.body.readUtf8())
            assertEquals("56789",server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)!!.body.readUtf8())
            assertEquals(claim.work.request,f.store.resourceUploads().single().request)
        } finally {observer?.cancelAndJoin();coordinator?.close();scheduler.closeAndDrain();f.close();server.close()}
    }
    @Test fun restoredUploadsAndDownloadAreAllAdoptedBeforeReconciliationAndBlockNewBytes()=runBlocking<Unit> {
        val f=ResourceSystemUploadTests().Fixture("https://objects.invalid/upload")
        val d=ResourceSystemDownloadTests().Fixture("https://objects.invalid/download")
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,uploadTransferLimit=1,downloadTransferLimit=1,interactiveByteReserve=0))
        val admission=AccountSystemTransferAdmission(context,f.store.resourceScope,scheduler)
        val uploadDriver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        val downloadDriver=ResourceSystemDownloadDriver(context,TestResourceDownloadJobService::class.java)
        val uploads=AccountSystemUploads(context,f.store,f.files,null,uploadDriver,admission)
        val downloads=AccountSystemDownloads(context,f.store,f.files,null,downloadDriver,admission)
        var waiting:Job?=null
        try {
            repeat(3) {
                val claim=f.prepare();val registration=f.registrations(claim).single()
                val mapping=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single()
                uploadDriver.schedule(f.store,f.files,mapping,registration.target)
            }
            val descriptor=d.descriptor
            f.store.applyResourceDirectoryPage(f.store.beginResourceDirectoryScan(d.room),RoomResourcePage(persistentListOf(
                RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100,0,descriptor.key.media),1000,descriptor)),100,null))
            val work=f.store.enqueueResourceDownload(descriptor.key,f.store.resourceSources(descriptor.key).sources.single())
            val target=d.fresh();val claim=f.store.claimResourceDownload(work.id,id(),System.currentTimeMillis())!!
            val mapping=f.store.installBackgroundDownload(claim,id(),id(),target)
            downloadDriver.schedule(f.store,f.files,mapping,target)
            admission.prepare();admission.prepare()
            assertEquals(4,scheduler.snapshot().active);assertEquals(3,scheduler.snapshot().activeUploads);assertEquals(1,scheduler.snapshot().activeDownloads)
            val entered=CompletableDeferred<Unit>()
            waiting=launch {scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download)) {entered.complete(Unit)}}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            assertFalse(entered.isCompleted)
            uploads.close();assertEquals(1,scheduler.snapshot().activeDownloads);assertFalse(entered.isCompleted)
            downloads.close();withTimeout(5000) {entered.await();waiting.join()}
            assertEquals(0,scheduler.snapshot().active);assertEquals(0,scheduler.snapshot().waiting)
        } finally {waiting?.cancelAndJoin();uploads.close();downloads.close();scheduler.closeAndDrain();f.close();d.cleanup()}
    }

    @Test fun orphanedNativeRecordIsDrainedBeforeItsAdoptedPermitIsReleased()=runBlocking<Unit> {
        val f=ResourceSystemUploadTests().Fixture("https://objects.invalid/orphan")
        val scheduler=AccountWorkScheduler();val admission=AccountSystemTransferAdmission(context,f.store.resourceScope,scheduler)
        val driver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        val coordinator=AccountSystemUploads(context,f.store,f.files,null,driver,admission)
        try {
            val claim=f.prepare();val registration=f.registrations(claim).single()
            val mapping=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single()
            driver.schedule(f.store,f.files,mapping,registration.target)
            // Crash gap: protected business state retired first, the native journal/job still exists.
            f.store.completeBackgroundUpload(mapping,null)
            admission.prepare();assertEquals(1,scheduler.snapshot().activeUploads)
            coordinator.recover()
            assertEquals(0,scheduler.snapshot().activeUploads)
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task)))
            assertTrue(ResourceSystemUploadJournal.records(context).none {it.mapping==mapping})
            assertTrue(f.store.backgroundUploadSources().isEmpty())
        } finally {coordinator.close();scheduler.closeAndDrain();f.close()}
    }
}
