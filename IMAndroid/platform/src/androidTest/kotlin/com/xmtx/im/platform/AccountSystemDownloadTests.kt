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
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class AccountSystemDownloadTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val uploads=object:ResourceUploadControl {
        override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("No uploads")
        override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("No uploads")
        override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("No uploads")
        override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("No uploads")
        override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("No uploads")
    }
    private inner class Fixture(val url:String,val scheduler:AccountWorkScheduler=AccountWorkScheduler()) {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val body="account-system-download"
        val store=SqliteClientStore(context,actor,device)
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"下载.txt","text/plain",body.length.toLong(),
            ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(body.toByteArray()).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
        val descriptors=mutableMapOf(descriptor.key.media to descriptor)
        val resolutions=AtomicInteger();val foregroundBytes=AtomicInteger();var grants=true;var issuedAheadMillis=0L
        var onResolve:suspend (Int)->Unit={}
        val targets=MediaTargetResolving {media,message,size->
            val number=resolutions.incrementAndGet();onResolve(number)
            val value=descriptors.getValue(media);val now=System.currentTimeMillis()
            val grant=ResourceBackgroundDownloadAuthorization(id(),value.byteCount,value.checksum!!,now+issuedAheadMillis,now+120000)
            MediaDownloadTargetClient(object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unused")
                override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url",url);put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                    put("expiresAtUnixMilliseconds",grant.expiresAt);put("expectedByteCount",value.byteCount);put("checksum",value.checksum!!.payload())
                    if(grants) put("backgroundDownloadAuthorization",grant.payload())
                })})
            }).resolve(media,message,size)
        }
        val driver=ResourceSystemDownloadDriver(context,TestResourceDownloadJobService::class.java)
        val activity=AccountResourceActivity(context,store,uploads,targets=targets,systemDownloads=driver,scheduler=scheduler,download={_,file->foregroundBytes.incrementAndGet();file.writeText(body)})
        suspend fun enqueue():ResourceDownloadWork {
            store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(descriptors.values.mapIndexed {index,value->
                RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-index,0,value.key.media),1000,value)
            }.toPersistentList(),100,null))
            return store.enqueueResourceDownload(descriptor.key,store.resourceSources(descriptor.key).sources.single())
        }
        suspend fun mapping():ResourceBackgroundDownloadMapping=withTimeout(10000) {
            var found:ResourceBackgroundDownloadMapping?=null
            while(found==null) {
                found=store.activeBackgroundDownloads().singleOrNull()?.mapping?.takeIf {context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(it.task))!=null}
                if(found==null) delay(10)
            };found
        }
        suspend fun close() {activity.close();assertEquals(0,scheduler.snapshot().active);assertEquals(0,scheduler.snapshot().waiting);scheduler.closeAndDrain();store.close()}
    }
    private suspend fun until(block:suspend ()->Boolean)=withTimeout(10000) {while(!block()) delay(10)}
    @Test fun durableNativeDownloadWaitsForSharedRetryQuotaBeforeRegisteringItsJob()=runBlocking<Unit> {
        val clock=java.util.concurrent.atomic.AtomicLong(0)
        val f=Fixture("https://objects.invalid/retry",AccountWorkScheduler(nowMillis=clock::get));var run:Job?=null
        f.onResolve={val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(intent.isRetry);assertEquals(NetworkWorkPriority.Interactive,intent.priority)}
        try {
            repeat(5) {f.scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Upload,isRetry=true)) {}}
            f.enqueue();run=launch {f.activity.runBackground(15000)}
            until {f.scheduler.snapshot().waitingByteTransfers==1}
            val mapping=f.store.activeBackgroundDownloads().single().mapping
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(mapping.task)))
            assertEquals(0,f.foregroundBytes.get());assertEquals(ResourceTransferWaitingReason.ServiceCooldown,f.activity.transferWaiting.state.value[ResourceTransferId(ResourceTransferKind.Download,mapping.download)])
            clock.set(2000);f.scheduler.setDegraded(false)
            assertEquals(mapping,f.mapping());assertEquals(1,f.scheduler.snapshot().activeDownloads);assertTrue(f.activity.transferWaiting.state.value.isEmpty())
        } finally {run?.cancelAndJoin();f.close()}
    }
    @Test fun accountCloseCancelsQueuedNativeAdmissionWithoutStartingAnotherGet()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/queued")
        val held=List(2) {f.scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download))}
        try {
            f.enqueue();val background=launch {f.activity.runBackground(15000)}
            until {f.scheduler.snapshot().waitingByteTransfers==1}
            val mapping=f.store.activeBackgroundDownloads().single().mapping
            assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(mapping.task)))
            withTimeout(5000) {f.activity.close();background.join()}
            assertEquals(0,f.scheduler.snapshot().waiting);assertEquals(2,f.scheduler.snapshot().activeDownloads)
            assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertEquals(0,f.foregroundBytes.get())
        } finally {held.forEach {f.scheduler.release(it)};f.close()}
    }
    private suspend fun force(mapping:ResourceBackgroundDownloadMapping)=ResourceSystemDownloadTests().force(mapping.task)
    private suspend fun <T> https(block:suspend (MockWebServer)->T):T {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        File(context.noBackupFilesDir,"system-download-test-ca.pem").writeText(cert.certificatePem())
        val keys=HandshakeCertificates.Builder().heldCertificate(cert).build()
        return MockWebServer().use {it.useHttps(keys.sslSocketFactory(),false);it.start();block(it)}
    }
    @Test fun foregroundUsesOrdinaryDownloadAndMissingDelegationGrantFallsBackOnce()=runBlocking<Unit> {
        for(background in listOf(false,true)) {
            val f=Fixture("https://objects.invalid/fallback");f.grants=!background
            try {
                val initial=f.enqueue()
                if(background) assertEquals(ResourceBackgroundRunResult.Completed,f.activity.runBackground(10000))
                else {val run=launch {f.activity.runForeground()};until {f.store.resourceDownloads().single().work.terminal};run.cancelAndJoin()}
                val work=f.store.resourceDownloads().single().work
                assertEquals(initial.id,work.id);assertEquals(ResourceDownloadPhase.Completed,work.phase)
                assertEquals(1,f.foregroundBytes.get());assertEquals(1,f.resolutions.get());assertTrue(f.store.activeBackgroundDownloads().isEmpty())
            } finally {f.close()}
        }
    }
    @Test fun explicitBackgroundHandsOffOnceThenFreshlyAuthorizesAndPublishes()=runBlocking<Unit> {
        https {server->val f=Fixture(server.url("/original").toString())
            f.issuedAheadMillis=250
            f.onResolve={val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(intent.isRetry);assertEquals(NetworkWorkPriority.Interactive,intent.priority)}
            try {
                server.enqueue(MockResponse().setBody(f.body));val initial=f.enqueue()
                val run=async {f.activity.runBackground(15000)};val mapping=f.mapping()
                assertFalse(run.isCompleted);assertEquals(0,f.foregroundBytes.get());force(mapping)
                assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(15000) {run.await()})
                val work=f.store.resourceDownloads().single().work;assertEquals(initial.id,work.id);assertEquals("issue=${work.issue}, attempts=${work.attempts}, requests=${server.requestCount}",ResourceDownloadPhase.Completed,work.phase)
                assertEquals(1,server.requestCount);assertEquals(2,f.resolutions.get());assertEquals(0,f.foregroundBytes.get())
                assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertTrue(f.driver.completions(mapping.systemSession).isEmpty())
                assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes)
                val reader=MessageOriginalFiles(f.targets,f.store,f.activity.files)
                f.onResolve={assertNull(currentCoroutineContext()[NetworkWorkIntent])}
                try {assertEquals(f.body,reader.withOriginal(f.descriptor.key,cacheOnly=true) {_,file->file.readText()})} finally {reader.close()}
            } finally {f.close()}
        }
    }
    @Test fun pauseCancelAndRevocationDrainRealSocketAndReleaseTheInbox()=runBlocking<Unit> {
        for(control in listOf("pause","cancel","revoke")) https {server->val f=Fixture(server.url("/slow").toString())
            try {
                server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE));val initial=f.enqueue()
                val run=async {f.activity.runBackground(15000)};val mapping=f.mapping();force(mapping)
                assertNotNull("$control: ${f.store.resourceDownloads().single().work}",withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)})
                when(control) {"pause"->f.store.controlResourceDownload(initial.id,ResourceDownloadControl.Pause);"cancel"->f.store.controlResourceDownload(initial.id,ResourceDownloadControl.Cancel);else->f.store.unavailable(f.room)}
                assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(10000) {run.await()})
                val work=f.store.resourceDownloads().single().work;assertFalse(work.backgroundPending);assertFalse(work.requested)
                when(control) {"pause"->assertEquals(ResourceDownloadControl.Pause,work.control);"cancel"->assertEquals(ResourceDownloadPhase.Stopped,work.phase);else->assertEquals(ResourceDownloadIssue.Unavailable,work.issue)}
                assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes);assertTrue(f.store.resourceFiles().isEmpty())
                assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(mapping.task)))
            } finally {f.close()}
        }
    }
    @Test fun stoppingBackgroundLeavesForegroundLeaseAndResumesOriginalIntent()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/not-started")
        try {
            val initial=f.enqueue();val background=launch {f.activity.runBackground()};val mapping=f.mapping()
            val foreground=launch(start=CoroutineStart.UNDISPATCHED) {f.activity.runForeground()}
            background.cancelAndJoin();assertFalse(foreground.isCompleted)
            assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes)
            until {f.store.resourceDownloads().single().work.terminal};assertEquals(initial.id,f.store.resourceDownloads().single().work.id)
            assertEquals(1,f.foregroundBytes.get());assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(mapping.task)))
            foreground.cancelAndJoin()
        } finally {f.close()}
    }
    @Test fun accountCloseCancelsBlockedFreshAuthorizationBeforeClosingFileOwnership()=runBlocking<Unit> {
        val f=ResourceSystemDownloadTests().Fixture("https://objects.invalid/received-close")
        val entered=CompletableDeferred<Unit>();var resolverDrained=false;var resolutions=0
        var activity:AccountResourceActivity?=null;var run:Job?=null
        try {
            // Start at the durable receipt boundary. An OS-interrupted GET can otherwise make
            // the second resolution a foreground retry instead of this publication phase.
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            ResourceSystemDownloadJournal.install(context,SystemDownloadRecord(f.mapping,f.store.resourceScope,f.target.target.plan,0,1,2))
            ResourceBackgroundDownloadInbox(context,f.store.resourceScope).receive(f.mapping,f.mapping.originDigest) {it.write(f.body.toByteArray())}
            f.reopen()
            val owner=AccountResourceActivity(context,f.store,uploads,systemDownloads=f.driver,targets={_,_,_->
                resolutions++;val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                assertTrue(intent.isRetry);assertEquals(NetworkWorkPriority.Interactive,intent.priority)
                assertTrue(f.store.activeBackgroundDownloads().single().received)
                assertTrue(f.store.resourceDownloads().single().work.backgroundPending)
                entered.complete(Unit);try {awaitCancellation()} finally {resolverDrained=true}
            },download={_,_->error("Received bytes must not be downloaded again")})
            activity=owner;run=launch {owner.runForeground()}
            withTimeout(10000) {entered.await();owner.close();run.join()}
            assertTrue(resolverDrained);assertEquals(1,resolutions)
            assertEquals(ResourceDownloadPhase.Stopped,f.store.resourceDownloads().single().work.phase)
            assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertTrue(f.store.backgroundDownloadSources().isEmpty());assertTrue(f.store.resourceFiles().isEmpty())
        } finally {run?.cancelAndJoin();activity?.close();f.cleanup()}
    }
    @Test fun freshAuthorizationRetrySurvivesSessionRestartWithoutAnotherGet()=runBlocking<Unit> {
        https {server->val f=Fixture(server.url("/retry").toString())
            f.onResolve={number->if(number==2) throw ClientFailure.Http(429,retryAfter="1")}
            try {
                server.enqueue(MockResponse().setBody(f.body));f.enqueue();val background=launch {f.activity.runBackground()};val mapping=f.mapping();force(mapping)
                until {f.store.resourceDownloads().single().work.issue==ResourceDownloadIssue.Network}
                background.cancelAndJoin()
                val saved=f.store.resourceDownloads().single().work;assertEquals(2,saved.attempts);assertTrue(saved.serverRetryAt>0);assertTrue(saved.backgroundPending)
                SqliteClientStore(context,f.actor,f.device).use {reopened->assertEquals(saved,reopened.resourceDownloads().single().work);assertTrue(reopened.activeBackgroundDownloads().single().received)}
                val foreground=launch {f.activity.runForeground()};until {f.store.resourceDownloads().single().work.terminal};foreground.cancelAndJoin()
                assertEquals(ResourceDownloadPhase.Completed,f.store.resourceDownloads().single().work.phase)
                assertEquals(1,server.requestCount);assertEquals(3,f.resolutions.get());assertEquals(0,f.foregroundBytes.get())
                assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes)
            } finally {f.close()}
        }
    }
    @Test fun restoredReceiptGapPublishesWithoutForegroundByteTransport()=runBlocking<Unit> {
        val f=ResourceSystemDownloadTests().Fixture("https://objects.invalid/received")
        var activity:AccountResourceActivity?=null
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            ResourceSystemDownloadJournal.install(context,SystemDownloadRecord(f.mapping,f.store.resourceScope,f.target.target.plan,0,1,2))
            ResourceBackgroundDownloadInbox(context,f.store.resourceScope).receive(f.mapping,f.mapping.originDigest) {it.write(f.body.toByteArray())}
            f.reopen();activity=AccountResourceActivity(context,f.store,uploads,targets={_,_,_->f.fresh().target},systemDownloads=f.driver,download={_,_->error("No second GET")})
            val run=launch {activity.runForeground()};until {f.store.resourceDownloads().single().work.terminal};run.cancelAndJoin()
            assertEquals(ResourceDownloadPhase.Completed,f.store.resourceDownloads().single().work.phase)
            assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertEquals(0L,activity.files.storageSnapshot().temporaryReservedBytes)
        } finally {activity?.close();f.cleanup()}
    }
    @Test fun nativeAndForegroundQueueShareTwoSlotsAndTighterPolicyDrainsQueuedJobs()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/queued")
        try {
            repeat(2) {index->val extra=f.descriptor.copy(key=ResourceKey(ResourceHome.Room(f.room),id()),checksum=ResourceChecksum((index+1).toString().padStart(64,'0')));f.descriptors[extra.key.media]=extra}
            f.enqueue();for(value in f.descriptors.values.filter {it!=f.descriptor}) f.store.enqueueResourceDownload(value.key,f.store.resourceSources(value.key).sources.single())
            val run=async {f.activity.runBackground(15000)}
            until {f.store.activeBackgroundDownloads().size==2};delay(100)
            assertEquals(2,f.resolutions.get());assertEquals(2,f.store.resourceDownloads().count {it.work.attempts==1});assertEquals(1,f.store.resourceDownloads().count {it.work.attempts==0})
            // Also pause the not-yet-admitted third task; the policy update must drain both native tasks.
            f.store.resourceDownloads().first {it.work.attempts==0}.work.let {f.store.controlResourceDownload(it.id,ResourceDownloadControl.Pause)}
            f.store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,false))
            assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(10000) {run.await()})
            assertEquals(2,f.store.resourceDownloads().count {it.work.issue==ResourceDownloadIssue.Policy});assertTrue(f.store.activeBackgroundDownloads().isEmpty())
            assertEquals(0L,f.activity.files.storageSnapshot().temporaryReservedBytes);assertEquals(0,f.foregroundBytes.get())
        } finally {f.close()}
    }
}
