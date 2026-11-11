package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class AccountSystemUploadTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture(val url:String) {
        val actor=UserId(id());val store=SqliteClientStore(context,actor,DeviceId(id()))
        val source=File.createTempFile("account-system-",".txt",context.cacheDir).apply {writeText("0123456789")}
        val grants=AtomicInteger();val transfers=AtomicInteger();val statuses=AtomicInteger();val finalizes=AtomicInteger()
        var reject=false
        var statusGate:CompletableDeferred<Unit>?=null
        private var session:ResourceUploadSession?=null
        private val control=object:ResourceUploadControl,ResourceBackgroundUploadControl {
            override suspend fun create(request:ResourceUploadRequest)=session ?: ResourceUploadSession(ResourceUploadLocator(request.usage.home(actor),id()),request.media,1,
                ResourceSessionState.Created,ResourceState.Pending,System.currentTimeMillis()+600_000,null,persistentListOf(),null).also {session=it}
            override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession {statuses.incrementAndGet();statusGate?.await();return session!!}
            override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest)=ResourceTransferPlan(ResourceTransferMode.Put,url,persistentListOf(),persistentMapOf(),null,System.currentTimeMillis()+60_000,request.byteCount,null,null,request.checksum)
            override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession {
                finalizes.incrementAndGet()
                return session.copy(state=ResourceSessionState.Completed,resourceState=ResourceState.Ready,bindableUntil=System.currentTimeMillis()+60_000).also {this@Fixture.session=it}
            }
            override suspend fun cancel(session:ResourceUploadSession)=session.copy(state=ResourceSessionState.Cancelled).also {this@Fixture.session=it}
            override suspend fun backgroundTargets(session:ResourceUploadSession,request:ResourceUploadRequest,parts:PersistentList<Int>):PersistentList<ResourceBackgroundUploadTarget> {
                grants.incrementAndGet();if(reject) throw ClientFailure.Http(422)
                val now=System.currentTimeMillis()
                val grant=ResourceBackgroundUploadAuthorization(id(),session.locator.session,session.generation,request.media,ResourceBackgroundUploadScope.Whole(request.byteCount,request.checksum),now,now+60_000)
                val plan=buildJsonObject {
                    put("version",1);put("mode","http_put");put("url",url);put("headers",JsonArray(emptyList()));put("formFields",buildJsonObject {})
                    put("expiresAtUnixMilliseconds",grant.expiresAt);put("expectedByteCount",request.byteCount);put("checksum",request.checksum.payload());put("backgroundAuthorization",grant.payload())
                }
                val api=object:AuthenticatedTransport {
                    override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unexpected request")
                    override suspend fun requestArray(path:String,payload:JsonObject,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {},arrayBody=JsonArray(listOf(plan)))
                }
                return ResourceUploadClient(api,actor).backgroundTargets(session,request)
            }
        }
        val scheduler=AccountWorkScheduler()
        val driver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        val activity=AccountResourceActivity(context,store,control,systemUploads=driver,scheduler=scheduler) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {transfers.incrementAndGet();files.withOriginal(upload=work.id) {assertEquals("0123456789",it.readText())}}
        }}
        suspend fun prepare():ResourceUploadWork {
            val asset=activity.files.importFile(source,"附件.txt","text/plain",ResourceUsage.Attachment(RoomId(id())),1024)
            return store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
        }
        suspend fun mapping():ResourceBackgroundUploadMapping=withTimeout(10_000) {
            var found:ResourceBackgroundUploadMapping?=null
            while(found==null) {
                found=store.activeBackgroundUploads().singleOrNull()?.takeIf {context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(it.task))!=null}
                if(found==null) delay(10)
            }
            found
        }
        suspend fun close() {statusGate?.complete(Unit);activity.close();assertEquals(0,scheduler.snapshot().active);assertEquals(0,scheduler.snapshot().waiting);scheduler.closeAndDrain();store.close();source.delete()}
    }
    private suspend fun until(block:suspend ()->Boolean)=withTimeout(10_000) {while(!block()) delay(10)}
    @Test fun pausedQueuedHandoffDrainsWithoutHoldingTheLifecycleMutexOrStartingAJob()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/queued")
        val held=List(2) {f.scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Upload))}
        try {
            val work=f.prepare();val background=async {f.activity.runBackground(15000)}
            until {f.scheduler.snapshot().waitingByteTransfers==1}
            val mapping=f.store.activeBackgroundUploads().single()
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task)))
            f.store.controlResourceUpload(work.id,true)
            assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(5000) {background.await()})
            assertEquals(0,f.scheduler.snapshot().waiting);assertEquals(2,f.scheduler.snapshot().activeUploads)
            assertTrue(f.store.activeBackgroundUploads().isEmpty());assertEquals(0,f.transfers.get())
            val paused=f.store.resourceUploads().single();assertTrue(paused.execution.userPaused);assertEquals(work.request,paused.request)
        } finally {held.forEach {f.scheduler.release(it)};f.close()}
    }
    private suspend fun force(mapping:ResourceBackgroundUploadMapping) {
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(mapping.task)}").use {
            val result=android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText();assertTrue(result,result.contains("Running job"))
        }
    }
    private suspend fun <T> https(block:suspend (MockWebServer)->T):T {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeText(certificate.certificatePem())
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        return MockWebServer().use {it.useHttps(keys.sslSocketFactory(),false);it.start();block(it)}
    }
    @Test fun foregroundNeverRequestsDelegationAndUnsupportedBackgroundUsesTheSameUpload()=runBlocking<Unit> {
        for(background in listOf(false,true)) {
            val f=Fixture("https://objects.invalid/unused");f.reject=true
            try {
                val work=f.prepare()
                if(background) assertEquals(ResourceBackgroundRunResult.Completed,f.activity.runBackground(10_000))
                else {val running=launch {f.activity.runForeground()};until {f.store.resourceUploads().single().terminal};running.cancelAndJoin()}
                assertEquals(if(background) 1 else 0,f.grants.get());assertEquals(1,f.transfers.get());assertEquals(1,f.finalizes.get())
                assertEquals(work.request,f.store.resourceUploads().single().request);assertTrue(f.store.activeBackgroundUploads().isEmpty())
            } finally {f.close()}
        }
    }
    @Test fun explicitBackgroundHandsOffOnceAndWaitsForAuthoritativeFinalize()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/account").toString());server.enqueue(MockResponse().setResponseCode(204))
            try {
                val work=f.prepare();val background=async {f.activity.runBackground(15_000)};val mapping=f.mapping()
                assertFalse(background.isCompleted);assertEquals(0,f.transfers.get());assertNull(f.store.resourceUploads().single().execution.owner)
                force(mapping)
                assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(15_000) {background.await()})
                assertEquals(1,server.requestCount);assertEquals("0123456789",server.takeRequest().body.readUtf8())
                assertEquals(1,f.grants.get());assertEquals(1,f.finalizes.get());assertEquals(0,f.transfers.get())
                assertEquals(work.request,f.store.resourceUploads().single().request);assertEquals(ResourceUploadStage.Ready,f.store.resourceUploads().single().stage)
                assertTrue(f.store.activeBackgroundUploads().isEmpty());assertTrue(f.driver.completions(mapping.systemSession).isEmpty())
                assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes)
            } finally {f.close()}
        }
    }
    private suspend fun controlDuringSystemBytes(cancel:Boolean)=coroutineScope {
        https {server->
            val f=Fixture(server.url("/control").toString());server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            try {
                val work=f.prepare();val background=async {f.activity.runBackground(15_000)};val mapping=f.mapping();force(mapping)
                assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)})
                if(cancel) f.store.requestResourceUploadCancellation(work.id) else f.store.controlResourceUpload(work.id,true)
                assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(10_000) {background.await()})
                val result=f.store.resourceUploads().single();assertFalse(result.execution.backgroundPending);assertEquals(0,result.execution.backgroundAttempts)
                if(cancel) assertEquals(ResourceUploadStage.Cancelled,result.stage) else {assertTrue(result.execution.userPaused);assertEquals(ResourceUploadAction.Status,result.execution.next)}
                assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task)))
                assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes);assertEquals(0,f.transfers.get());assertEquals(0,f.finalizes.get())
                withSystemUploadSourceLock(context,mapping.task) {assertTrue(f.store.activeBackgroundUploads().isEmpty())}
            } finally {f.close()}
        }
    }
    @Test fun pauseDrainsActualSystemBytesWithoutSpendingFailureBudget()=runBlocking<Unit> {controlDuringSystemBytes(false)}
    @Test fun cancellationDrainsActualSystemBytesBeforeRemoteCancellation()=runBlocking<Unit> {controlDuringSystemBytes(true)}

    @Test fun stoppingBackgroundDrainsSystemTasksAndKeepsForegroundLease()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/not-started");f.statusGate=CompletableDeferred()
        try {
            f.prepare();val background=launch {f.activity.runBackground()};val mapping=f.mapping()
            val foreground=launch(start=CoroutineStart.UNDISPATCHED) {f.activity.runForeground()}
            background.cancelAndJoin();assertFalse(foreground.isCompleted)
            assertTrue(f.store.activeBackgroundUploads().isEmpty());assertFalse(f.store.resourceUploads().single().execution.backgroundPending)
            assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes)
            until {f.statuses.get()==1};f.statusGate!!.complete(Unit)
            until {f.store.resourceUploads().single().terminal};assertEquals(1,f.grants.get());assertEquals(1,f.transfers.get())
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task)))
            foreground.cancelAndJoin()
        } finally {f.close()}
    }
    @Test fun accountCloseDrainsSystemSocketBeforeDatabaseClose()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/close").toString());server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            try {
                f.prepare();val background=launch {f.activity.runBackground()};val mapping=f.mapping();force(mapping)
                assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)})
                withTimeout(10_000) {f.activity.close();background.join()}
                assertTrue(background.isCancelled);assertTrue(f.store.activeBackgroundUploads().isEmpty());assertTrue(f.store.backgroundUploadSources().isEmpty())
                withSystemUploadSourceLock(context,mapping.task) {assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task)))}
                f.store.close();f.activity.close()
            } finally {f.close()}
        }
    }
    @Test fun recoveryRetiresUnscheduledMappingAndReleasesItsPublishedSource()=runBlocking<Unit> {
        for(retired in listOf(false,true)) {
          val f=ResourceSystemUploadTests().Fixture("https://objects.invalid/crash")
          try {
            val claim=f.prepare();val mapping=f.install(claim).single();f.files.prepareBackgroundUploadSource(mapping)
            if(retired) f.store.completeBackgroundUpload(mapping,null)
            f.reopen()
            val coordinator=AccountSystemUploads(context,f.store,f.files,null,ResourceSystemUploadDriver(context))
            coordinator.recover()
            val work=f.store.resourceUploads().single();assertEquals(claim.work.request,work.request);assertFalse(work.execution.backgroundPending)
            assertEquals(ResourceUploadAction.Status,work.execution.next);assertEquals(1,work.execution.backgroundAttempts)
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);assertFalse(work.sourceReleased)
            coordinator.close()
          } finally {f.close()}
        }
    }
    @Test fun failedSystemAdmissionDrainsTheWholeInstalledBatchAndKeepsItsUploadIdentity()=runBlocking<Unit> {
        val f=ResourceSystemUploadTests().Fixture("https://objects.invalid/not-enqueued")
        try {
            val claim=f.prepare();val targets=f.registrations(claim,true).map {it.target}.toPersistentList()
            val control=object:ResourceBackgroundUploadControl {
                override suspend fun backgroundTargets(session:ResourceUploadSession,request:ResourceUploadRequest,parts:PersistentList<Int>)=targets
            }
            val coordinator=AccountSystemUploads(context,f.store,f.files,control,ResourceSystemUploadDriver(context,UnregisteredResourceJobService::class.java))
            coordinator.enable();assertTrue(coordinator.delegate(claim))
            val work=f.store.resourceUploads().single();assertEquals(claim.work.request,work.request);assertFalse(work.execution.backgroundPending)
            assertEquals(1,work.execution.backgroundAttempts);assertEquals(ResourceUploadAction.Status,work.execution.next)
            assertTrue(f.store.activeBackgroundUploads().isEmpty());assertTrue(ResourceSystemUploadJournal.records(context).none {it.mapping.systemSession==f.store.backgroundUploadSession()})
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);coordinator.close()
        } finally {f.close()}
    }
    @Test fun engineCancellationAfterAtomicHandoffCannotWriteThroughItsOldClaim()=runBlocking<Unit> {
        val f=ResourceSystemUploadTests().Fixture("https://objects.invalid/handoff");var engine:ResourceUploadEngine?=null
        try {
            val prepared=f.prepare();f.store.finishResourceUpload(prepared,prepared.work.session,ResourceUploadAction.Upload,f.now)
            val installed=CompletableDeferred<ResourceBackgroundUploadMapping>();var failureWrites=0
            val journal=object:ResourceUploadJournal by f.store {
                override suspend fun failResourceUpload(claim:ResourceUploadClaim,error:ResourceUploadError,retryAt:Long?,serverRetryAt:Long,cancelled:Boolean,session:ResourceUploadSession?) {
                    failureWrites++;f.store.failResourceUpload(claim,error,retryAt,serverRetryAt,cancelled,session)
                }
            }
            val control=object:ResourceUploadControl {
                override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("unexpected create")
                override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("unexpected status")
                override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("unexpected target")
                override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("unexpected finalize")
                override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("unexpected cancel")
            }
            engine=ResourceUploadEngine(journal,control,ManagedResourceUploadBytes(f.files),now={f.now},delegate={claim->
                installed.complete(f.install(claim).single());awaitCancellation()
            })
            engine.start(false);val running=async {engine.resume(prepared.work.id)};val mapping=withTimeout(5000) {installed.await()}
            val before=f.store.resourceUploads().single().execution
            engine.close();running.join();assertTrue(running.isCancelled);assertEquals(0,failureWrites)
            assertTrue(before.backgroundPending);assertEquals(before,f.store.resourceUploads().single().execution)
            f.store.completeBackgroundUpload(mapping,null)
        } finally {engine?.close();f.close()}
    }
}

/** Deliberately absent from the test manifest, to exercise failure after encrypted admission. */
class UnregisteredResourceJobService:ResourceUploadJobService()
