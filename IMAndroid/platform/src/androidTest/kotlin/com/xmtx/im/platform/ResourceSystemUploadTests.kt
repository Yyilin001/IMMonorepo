package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ResourceSystemUploadTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    internal inner class Fixture(val url:String) {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=System.currentTimeMillis()
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        val source=File.createTempFile("background-journal-",".txt",context.cacheDir).apply {writeText("0123456789")}
        suspend fun prepare():ResourceUploadClaim {
            val asset=files.importFile(source,"记录.txt","text/plain",ResourceUsage.Attachment(room),1024)
            val work=store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut),asset.displayName))
            val owner=id();val create=store.claimResourceUpload(work.id,owner,now)!!
            val remote=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),work.request.media,1,ResourceSessionState.Created,ResourceState.Pending,now+3_600_000,null,persistentListOf(),null)
            store.finishResourceUpload(create,remote,ResourceUploadAction.Upload,now)
            return store.claimResourceUpload(work.id,owner,now)!!
        }
        suspend fun next(upload:String):ResourceUploadClaim {
            val work=store.resourceUploads().first {it.id==upload};now=maxOf(now,work.execution.retryAt)
            val status=store.claimResourceUpload(upload,id(),now)!!
            store.finishResourceUpload(status,work.session,ResourceUploadAction.Upload,now)
            return store.claimResourceUpload(upload,id(),now)!!
        }
        suspend fun registrations(claim:ResourceUploadClaim,parts:Boolean=false):PersistentList<ResourceBackgroundUploadRegistration> {
            val session=claim.work.session!!;val request=claim.work.request
            val plans=(if(parts) listOf(1,2) else listOf(0)).map {number->
                val scope=if(number==0) ResourceBackgroundUploadScope.Whole(request.byteCount,request.checksum) else ResourceBackgroundUploadScope.Part(number)
                val grant=ResourceBackgroundUploadAuthorization(id(),session.locator.session,session.generation,request.media,scope,now,now+60000)
                buildJsonObject {
                    put("version",1);put("mode",if(parts) "http_part_put" else "http_put");put("url",url)
                    put("headers",JsonArray(emptyList()));put("formFields",buildJsonObject {});put("expiresAtUnixMilliseconds",grant.expiresAt)
                    put("expectedByteCount",if(parts) 5 else 10)
                    if(parts) {put("partNumber",number);put("byteRange",ResourceRange((number-1)*5L,number*5L-1).payload())} else put("checksum",request.checksum.payload())
                    put("backgroundAuthorization",grant.payload())
                }
            }
            val api=object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unexpected request")
                override suspend fun requestArray(path:String,payload:JsonObject,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {},arrayBody=JsonArray(plans))
            }
            val targets=ResourceUploadClient(api,actor,{now},{1000}).backgroundTargets(session,request,if(parts) persistentListOf(1,2) else persistentListOf())
            return targets.map {ResourceBackgroundUploadRegistration(id(),id(),it)}.toPersistentList()
        }
        suspend fun install(claim:ResourceUploadClaim,parts:Boolean=false)=store.installBackgroundUploads(claim,registrations(claim,parts),now)
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun close() {files.close();store.close();source.delete()}
    }
    private suspend fun force(task:String) {
        val shell="cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(task)}"
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(shell).use {descriptor->
            val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().readText()
            assertTrue(output,output.contains("Running job"))
        }
    }
    private suspend fun completion(driver:ResourceSystemUploadDriver,mapping:ResourceBackgroundUploadMapping)=withTimeout(15000) {
        var result:ResourceBackgroundUploadResult?=null
        while(result==null) {result=driver.completions(mapping.systemSession).firstOrNull {it.mapping==mapping.id};if(result==null) delay(25)}
        result
    }
    private suspend fun <T> https(block:suspend (okhttp3.mockwebserver.MockWebServer)->T):T {
        val certificate=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeText(certificate.certificatePem())
        val keys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(certificate).build()
        return okhttp3.mockwebserver.MockWebServer().use {server->server.useHttps(keys.sslSocketFactory(),false);server.start();block(server)}
    }
    private fun driver()=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
    @Test fun runningUploadProgressIsAdoptedByAccountAndClearedBeforeSourceRelease()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/observed").toString());val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
            val scheduler=AccountWorkScheduler();var activity:AccountResourceActivity?=null
            val control=object:ResourceUploadControl {
                override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("unused")
                override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("unused")
                override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("unused")
                override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("unused")
                override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("unused")
            }
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.NO_RESPONSE))
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                driver.schedule(f.store,f.files,m,registration.target);force(m.task)
                assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)})
                val key=SystemTransferProgressKey(f.store.resourceScope,ResourceTransferKind.Upload,m.id,m.task)
                assertEquals(10L,systemTransferProgress.samples.value[key]!!.transferredBytes)
                f.reopen();f.files.close()
                val owner=AccountResourceActivity(context,f.store,control,systemUploads=driver,scheduler=scheduler);activity=owner
                assertTrue(owner.transferWaiting.snapshots.value.attempts.isEmpty());owner.prepareNetworkTransfers()
                val transfer=ResourceTransferId(ResourceTransferKind.Upload,claim.work.id)
                val sample=withTimeout(5000) {owner.transferWaiting.snapshots.first {it.attempts[transfer]!=null}}.attempts[transfer]!!
                assertEquals(m.id,sample.attemptId);assertEquals(10L,sample.expectedBytes);assertEquals(10L,sample.transferredBytes)
                assertTrue(f.store.resourceUploads().single().execution.backgroundPending);assertFalse(f.store.resourceUploads().single().terminal)
                owner.close();activity=null
                assertTrue(owner.transferWaiting.snapshots.value.attempts.isEmpty());assertFalse(systemTransferProgress.samples.value.containsKey(key))
                assertEquals(0,scheduler.snapshot().activeUploads)
                val metric=scheduler.transferDiagnostics.snapshot().backgrounds.single()
                assertTrue(metric.completionObserved);assertEquals(10L,metric.bodyBytesSent);assertEquals(true,metric.cancelled)
                assertNotNull(metric.cancellationToPermitReleaseNanos)
            } finally {activity?.close();mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};scheduler.closeAndDrain();f.close()}
        }
    }
    @Test fun actualJobSendsVerifiedBytesAndOnlyTheAccountReconcilesCompletion()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/upload?cap=PRIVATE-CAPABILITY").toString());val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setResponseCode(204))
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                driver.schedule(f.store,f.files,m,registration.target)
                val job=context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(m.task))!!
                assertEquals(setOf("task"),job.extras.keySet());assertEquals(m.task,job.extras.getString("task"));assertTrue(job.isPersisted)
                assertFalse(File(context.noBackupFilesDir,"resource-system-uploads.enc").readBytes().toString(Charsets.ISO_8859_1).contains("PRIVATE-CAPABILITY"))
                assertTrue(runCatching {driver.cancelAndDrain(m.copy(activation=id()))}.isFailure)
                force(m.task);val result=completion(driver,m);assertEquals(204,result.status);assertEquals(10L,result.sentBytes);assertEquals(m.originDigest,result.originDigest)
                assertEquals(ResourceBackgroundTransferObservation(10,0,204,false,false),result.observation)
                assertEquals("0123456789",server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)!!.body.readUtf8())
                assertTrue(f.store.resourceUploads().single().execution.backgroundPending);assertFalse(f.store.resourceUploads().single().terminal)
                assertNull(ResourceSystemUploadJournal.records(context).first {it.mapping==m}.plan)
                f.reopen();assertEquals(result.observation,driver.completions(m.systemSession).single().observation);assertEquals(1,driver.reconcile(f.store,f.files));assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
                val work=f.store.resourceUploads().single();assertEquals(ResourceUploadAction.Finalize,work.execution.next);assertFalse(work.terminal)
                assertEquals(0,driver.reconcile(f.store,f.files));assertTrue(driver.completions(m.systemSession).isEmpty())
            } finally {mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
        }
    }
    @Test fun cancellingAnActiveSystemJobDrainsTheSocketBeforeReleasingTheSource()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/cancel").toString());val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.NO_RESPONSE))
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                driver.schedule(f.store,f.files,m,registration.target);force(m.task)
                assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(10,java.util.concurrent.TimeUnit.SECONDS)})
                var acquired=false;val lockFailure=runCatching {withSystemUploadSourceLock(context,m.task) {acquired=true}}.exceptionOrNull()
                assertFalse(acquired);assertTrue(lockFailure is IllegalStateException)
                f.store.requestResourceUploadCancellation(claim.work.id)
                val result=withTimeout(10000) {driver.cancelAndDrain(m)}!!;assertNull(result.status)
                assertEquals(10L,result.observation!!.bodyBytesSent);assertTrue(result.observation!!.cancelled);assertTrue(result.observation!!.failed)
                assertEquals(1,driver.reconcile(f.store,f.files));assertEquals(ResourceUploadAction.Cancel,f.store.resourceUploads().single().execution.next)
                assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
            } finally {mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
        }
    }
    @Test fun providerBackpressureIsDurableAndNeverPublishesReady()=runBlocking<Unit> {
        https {server->
            val f=Fixture(server.url("/backpressure").toString());val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setResponseCode(503).setHeader("Retry-After","17"))
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                driver.schedule(f.store,f.files,m,registration.target);val before=System.currentTimeMillis();force(m.task)
                val result=completion(driver,m);assertEquals(503,result.status);assertTrue(result.retryNotBefore!!>=before+17000)
                assertEquals(503,result.observation!!.statusCode);assertFalse(result.observation!!.failed)
                driver.reconcile(f.store,f.files);val work=f.store.resourceUploads().single()
                assertFalse(work.terminal);assertEquals(1,work.execution.backgroundAttempts);assertEquals(result.retryNotBefore,work.execution.serverRetryAt)
            } finally {mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
        }
    }
    @Test fun defaultServiceDoesNotUseAnImplicitNetworkWhenSchedulerProvidesNone()=runBlocking<Unit> {
        org.junit.Assume.assumeTrue(context.getSystemService(android.net.ConnectivityManager::class.java).activeNetwork==null)
        val f=Fixture("https://localhost:1/no-network");val driver=ResourceSystemUploadDriver(context);var mapping:ResourceBackgroundUploadMapping?=null
        try {
            val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
            driver.schedule(f.store,f.files,m,registration.target);force(m.task)
            val result=completion(driver,m);assertNull(result.status);assertNotNull(result.error);assertNull(result.observation)
            driver.reconcile(f.store,f.files);assertEquals(1,f.store.resourceUploads().single().execution.backgroundAttempts)
        } finally {mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
    }
    @Test fun corruptEncryptedJournalStopsTheSystemJobWithoutSendingOrRetrying()=runBlocking<Unit> {
        org.junit.Assume.assumeTrue(context.getSystemService(android.net.ConnectivityManager::class.java).activeNetwork==null)
        https {server->
            val f=Fixture(server.url("/must-not-send").toString());val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
            val encrypted=File(context.noBackupFilesDir,"resource-system-uploads.enc");var backup:ByteArray?=null
            try {
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                driver.schedule(f.store,f.files,m,registration.target)
                backup=encrypted.readBytes();val corrupt=backup!!.copyOf();corrupt[corrupt.lastIndex]=(corrupt.last().toInt() xor 1).toByte();encrypted.writeBytes(corrupt)
                force(m.task)
                withTimeout(10000) {while(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(m.task))!=null) delay(25)}
                assertEquals(0,server.requestCount);assertTrue(f.store.resourceUploads().single().execution.backgroundPending)
                encrypted.writeBytes(backup!!);backup=null
                assertTrue(driver.completions(m.systemSession).isEmpty());f.files.withBackgroundUploadSource(m) {assertEquals("0123456789",it.readText())}
                driver.cancelAndDrain(m);driver.reconcile(f.store,f.files)
            } finally {backup?.let(encrypted::writeBytes);mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
        }
    }
    @Test fun persistedCancellationPreventsAnyLateJobFromStartingBytes()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/cancelled?private=token");val driver=driver();var mapping:ResourceBackgroundUploadMapping?=null
        try {
            val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
            driver.schedule(f.store,f.files,m,registration.target);driver.cancelAndDrain(m)
            driver.schedule(f.store,f.files,m,registration.target);driver.restore(m.systemSession)
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(m.task)))
            assertNull(ResourceSystemUploadJournal.start(context,m.task,ResourceSystemUploadDriver.boot(context),android.os.SystemClock.elapsedRealtime(),System.currentTimeMillis()))
            assertNull(driver.completions(m.systemSession).single().observation)
            assertEquals(1,driver.reconcile(f.store,f.files));assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {mapping?.let {driver.cancelAndDrain(it);driver.reconcile(f.store,f.files)};f.close()}
    }
    @Test fun persistedBudgetRejectsRebootClockRollbackExpiryAndRepeatedProcessRestarts()=runBlocking<Unit> {
        for(reason in listOf("boot","elapsed-backwards","elapsed-expired","wall-expired","attempts")) {
            val f=Fixture("https://objects.invalid/budget");var mapping:ResourceBackgroundUploadMapping?=null
            try {
                val claim=f.prepare();val registration=f.registrations(claim).single();val m=f.store.installBackgroundUploads(claim,persistentListOf(registration)).single();mapping=m
                val row=SystemUploadRecord(m,f.store.resourceScope,claim.work.request.checksum,registration.target.plan,1,1000,2000)
                ResourceSystemUploadJournal.install(context,row)
                ResourceSystemUploadJournal.install(context,row.copy(deadlineElapsed=3000))
                assertEquals(2000L,ResourceSystemUploadJournal.records(context).first {it.mapping==m}.deadlineElapsed)
                if(reason=="attempts") repeat(2) {assertNotNull(ResourceSystemUploadJournal.start(context,m.task,1,1500,f.now))}
                assertNull(ResourceSystemUploadJournal.start(context,m.task,if(reason=="boot") 2 else 1,
                    when(reason) {"elapsed-backwards"->999;"elapsed-expired"->2000;else->1500},if(reason=="wall-expired") registration.target.plan.expiresAt else f.now))
                assertNull(ResourceSystemUploadJournal.records(context).first {it.mapping==m}.plan)
                assertEquals(1,driver().reconcile(f.store,f.files))
            } finally {mapping?.let {driver().cancelAndDrain(it);driver().reconcile(f.store,f.files)};f.close()}
        }
    }
}

/** Test-only service pins this test's CA, including when Android creates a fresh process. */
class TestResourceUploadJobService:ResourceUploadJobService() {
    override fun uploader(params:android.app.job.JobParameters,now:()->Long):ResourcePlanUploader {
        File(noBackupFilesDir,"system-upload-worker-pid.txt").writeText(android.os.Process.myPid().toString())
        val certificate=java.security.cert.CertificateFactory.getInstance("X.509").let {factory->File(noBackupFilesDir,"system-upload-test-ca.pem").inputStream().use(factory::generateCertificate)} as java.security.cert.X509Certificate
        val trust=okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(certificate).build()
        return ResourcePlanUploader(okhttp3.OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build(),now)
    }
}
