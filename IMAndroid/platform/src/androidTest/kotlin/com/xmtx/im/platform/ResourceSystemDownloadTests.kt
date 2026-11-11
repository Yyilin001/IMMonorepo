package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ResourceSystemDownloadTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    internal inner class Fixture(val url:String) {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val body="system-download-bytes"
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"原件.txt","text/plain",body.length.toLong(),
            ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(body.toByteArray()).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        val driver=ResourceSystemDownloadDriver(context,TestResourceDownloadJobService::class.java)
        lateinit var mapping:ResourceBackgroundDownloadMapping;lateinit var target:ResourceBackgroundDownloadTarget
        suspend fun fresh():ResourceBackgroundDownloadTarget {
            val now=System.currentTimeMillis();val grant=ResourceBackgroundDownloadAuthorization(id(),descriptor.byteCount,descriptor.checksum!!,now,now+120000)
            return ResourceBackgroundDownloadTarget(MediaDownloadTargetClient(object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unused")
                override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url",url);put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                    put("expiresAtUnixMilliseconds",grant.expiresAt);put("expectedByteCount",grant.expectedBytes);put("checksum",grant.checksum.payload());put("backgroundDownloadAuthorization",grant.payload())
                })})
            }).resolve(descriptor.key.media,null,null))
        }
        suspend fun install() {
            store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100,0,descriptor.key.media),1000,descriptor)),100,null))
            val job=store.enqueueResourceDownload(descriptor.key,store.resourceSources(descriptor.key).sources.single())
            val claim=store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!;target=fresh()
            mapping=store.installBackgroundDownload(claim,id(),id(),target)
        }
        suspend fun schedule() {install();driver.schedule(store,files,mapping,target)}
        suspend fun reopen() {closeOwner();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun closeOwner() {files.close();store.close()}
        suspend fun cleanup() {
            if(::mapping.isInitialized) {
                val work=store.resourceDownloads().firstOrNull {it.work.id==mapping.download}?.work
                if(work!=null && !work.terminal) store.controlResourceDownload(work.id,ResourceDownloadControl.Cancel)
                driver.cancelAndDrain(mapping);driver.reconcile(store,files)
            }
            closeOwner()
        }
    }
    internal suspend fun force(task:String) {
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} ${systemDownloadJobId(task)}").use {fd->
            val result=android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).bufferedReader().readText();assertTrue(result,result.contains("Running job"))
        }
    }
    internal suspend fun completion(f:Fixture)=withTimeout(15000) {
        var result:ResourceBackgroundDownloadResult?=null
        while(result==null) {result=f.driver.completions(f.mapping.systemSession).firstOrNull {it.mapping==f.mapping.id};if(result==null) delay(20)}
        result
    }
    private suspend fun <T> https(block:suspend (okhttp3.mockwebserver.MockWebServer)->T):T {
        val cert=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        File(context.noBackupFilesDir,"system-download-test-ca.pem").writeText(cert.certificatePem())
        val keys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(cert).build()
        return okhttp3.mockwebserver.MockWebServer().use {server->server.useHttps(keys.sslSocketFactory(),false);server.start();block(server)}
    }
    @Test fun realSystemJobReceivesBytesButOnlyFreshAccountPublicationCompletesIt()=runBlocking<Unit> {
        https {server->val f=Fixture(server.url("/original?cap=PRIVATE-CAPABILITY").toString())
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setBody(f.body));f.schedule()
                val job=context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(f.mapping.task))!!
                assertTrue(job.isPersisted);assertEquals(setOf("task"),job.extras.keySet());assertEquals(f.mapping.task,job.extras.getString("task"))
                assertFalse(File(context.noBackupFilesDir,"resource-system-downloads.enc").readBytes().toString(Charsets.ISO_8859_1).contains("PRIVATE-CAPABILITY"))
                force(f.mapping.task);val result=completion(f);assertEquals(200,result.status);assertNull(result.issue);assertEquals(f.body.length.toLong(),result.receivedBytes)
                assertEquals(ResourceBackgroundTransferObservation(0,f.body.length.toLong(),200,false,false),result.observation)
                assertNull(server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)!!.getHeader("Range"))
                assertNull(ResourceSystemDownloadJournal.records(context).first {it.mapping==f.mapping}.plan)
                assertTrue(f.store.resourceFiles().isEmpty());f.reopen();assertEquals(result.observation,f.driver.completions(f.mapping.systemSession).single().observation);assertEquals(1,f.driver.reconcile(f.store,f.files))
                assertTrue(f.store.activeBackgroundDownloads().single().received);assertFalse(f.store.resourceDownloads().single().work.terminal)
                f.files.publishBackgroundDownload(f.mapping,f.fresh().target)
                assertEquals(f.body,f.files.withDownloaded(f.fresh().target,cacheOnly=true) {it.readText()})
                assertTrue(f.store.completeBackgroundDownload(f.mapping,f.store.selectMessageResource(f.descriptor.key)))
                f.driver.reconcile(f.store,f.files);assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);assertTrue(f.driver.completions(f.mapping.systemSession).isEmpty())
            } finally {f.cleanup()}
        }
    }
    @Test fun cancellationDrainsActiveSocketBeforeRemovingInboxAndCannotBeRescheduled()=runBlocking<Unit> {
        https {server->val f=Fixture(server.url("/slow").toString())
            try {
                server.enqueue(okhttp3.mockwebserver.MockResponse().setBody(f.body).throttleBody(1,1,java.util.concurrent.TimeUnit.SECONDS));f.schedule();force(f.mapping.task)
                assertNotNull(server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS))
                val key=SystemTransferProgressKey(f.store.resourceScope,ResourceTransferKind.Download,f.mapping.id,f.mapping.task)
                withTimeout(5000) {while((systemTransferProgress.samples.value[key]?.transferredBytes ?: 0)==0L) delay(5)}
                f.store.controlResourceDownload(f.mapping.download,ResourceDownloadControl.Cancel)
                val result=f.driver.cancelAndDrain(f.mapping)!!
                assertTrue(result.observation!!.bodyBytesReceived in 1 until f.body.length.toLong());assertTrue(result.observation!!.cancelled)
                assertEquals(0L,result.receivedBytes)
                f.driver.reconcile(f.store,f.files)
                assertEquals(ResourceDownloadPhase.Stopped,f.store.resourceDownloads().single().work.phase);assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
                f.driver.restore(f.mapping.systemSession);assertNull(context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(f.mapping.task)))
                assertFalse(File(context.noBackupFilesDir,"resources-${f.store.resourceScope}/background-downloads/${f.mapping.id}").exists())
            } finally {f.cleanup()}
        }
    }
    @Test fun transportFailurePreservesServerRetryFloorAndWrongBytesNeverBecomeReceived()=runBlocking<Unit> {
        https {server->for(code in listOf(429,200)) {val f=Fixture(server.url("/failed").toString())
            try {
                server.enqueue(if(code==429) okhttp3.mockwebserver.MockResponse().setResponseCode(429).setHeader("Retry-After","60") else okhttp3.mockwebserver.MockResponse().setBody("x".repeat(f.body.length)))
                f.schedule();force(f.mapping.task);val result=completion(f);f.driver.reconcile(f.store,f.files)
                val work=f.store.resourceDownloads().single().work
                if(code==429) {assertNotNull(result.retryNotBefore);assertEquals(result.retryNotBefore,work.serverRetryAt);assertTrue(work.requested)}
                else {assertEquals(ResourceDownloadIssue.Integrity,result.issue);assertFalse(work.requested)}
                assertTrue(f.store.activeBackgroundDownloads().isEmpty());assertTrue(f.store.resourceFiles().isEmpty());assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
            } finally {f.cleanup()}
        }}
    }
    @Test fun interruptedEnqueueRestoresOnceAndCancellationSurvivesLateSchedule()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/original?cap=private")
        try {
            f.schedule();val scheduler=context.getSystemService(android.app.job.JobScheduler::class.java);scheduler.cancel(systemDownloadJobId(f.mapping.task))
            f.driver.restore(f.mapping.systemSession);assertNotNull(scheduler.getPendingJob(systemDownloadJobId(f.mapping.task)))
            f.driver.cancelAndDrain(f.mapping);f.driver.schedule(f.store,f.files,f.mapping,f.target);f.driver.restore(f.mapping.systemSession)
            assertNull(scheduler.getPendingJob(systemDownloadJobId(f.mapping.task)));assertEquals(1,f.driver.reconcile(f.store,f.files))
        } finally {f.cleanup()}
    }
    @Test fun staleBootElapsedClockExpiryAndRestartBudgetCannotExtendTheOriginalRequest()=runBlocking<Unit> {
        for(reason in listOf("boot","rollback","elapsed","wall","attempts")) {val f=Fixture("https://objects.invalid/original")
            try {
                f.install();val row=SystemDownloadRecord(f.mapping,f.store.resourceScope,f.target.target.plan,1,1000,2000)
                ResourceSystemDownloadJournal.install(context,row);ResourceSystemDownloadJournal.install(context,row.copy(deadlineElapsed=3000))
                assertEquals(2000L,ResourceSystemDownloadJournal.records(context).first {it.mapping==f.mapping}.deadlineElapsed)
                if(reason=="attempts") repeat(2) {assertNotNull(ResourceSystemDownloadJournal.start(context,f.mapping.task,1,1500,System.currentTimeMillis()))}
                assertNull(ResourceSystemDownloadJournal.start(context,f.mapping.task,if(reason=="boot") 2 else 1,when(reason) {"rollback"->999;"elapsed"->2000;else->1500},
                    if(reason=="wall") f.mapping.authorization.expiresAt else System.currentTimeMillis()))
                assertNull(ResourceSystemDownloadJournal.records(context).first {it.mapping==f.mapping}.plan);assertEquals(1,f.driver.reconcile(f.store,f.files))
            } finally {f.cleanup()}
        }
    }
    @Test fun receivedBytesRecoverAcrossReceiptGapEvenWhenRequestCanNoLongerRun()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/already-received")
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            ResourceSystemDownloadJournal.install(context,SystemDownloadRecord(f.mapping,f.store.resourceScope,f.target.target.plan,0,1,2))
            ResourceBackgroundDownloadInbox(context,f.store.resourceScope).receive(f.mapping,f.mapping.originDigest) {it.write(f.body.toByteArray())}
            f.driver.restore(f.mapping.systemSession);val result=f.driver.completions(f.mapping.systemSession).single();assertEquals(200,result.status)
            assertEquals(1,f.driver.reconcile(f.store,f.files));f.files.publishBackgroundDownload(f.mapping,f.fresh().target)
            assertTrue(f.store.completeBackgroundDownload(f.mapping,f.store.selectMessageResource(f.descriptor.key)));f.driver.reconcile(f.store,f.files)
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {f.cleanup()}
    }
    @Test fun workerWaitsForShortRecoveryProbeInsteadOfReportingStorageFailure()=runBlocking<Unit> {
        val f=Fixture("https://objects.invalid/probe")
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            val task=UUID.fromString(f.mapping.task);val position=((task.mostSignificantBits xor task.leastSignificantBits) and Long.MAX_VALUE).coerceAtMost(Long.MAX_VALUE-1)
            java.io.RandomAccessFile(File(context.noBackupFilesDir,"resource-system-download.lock"),"rw").use {file->
                val probe=file.channel.lock(position,1,false)
                val writing=async(Dispatchers.IO) {ResourceBackgroundDownloadInbox(context,f.store.resourceScope).receive(f.mapping,f.mapping.originDigest) {it.write(f.body.toByteArray())}}
                try {delay(100);assertFalse(writing.isCompleted)} finally {probe.release()}
                withTimeout(5000) {writing.await()}
            }
            assertTrue(ResourceBackgroundDownloadInbox(context,f.store.resourceScope).hasReceived(f.mapping))
        } finally {f.cleanup()}
    }
}

/** Only CA trust is injected. Production network selection, policy checks, sockets and DNS remain in use. */
class TestResourceDownloadJobService:ResourceDownloadJobService() {
    override fun baseHttpClient():okhttp3.OkHttpClient {
        File(noBackupFilesDir,"system-download-worker-pid.txt").writeText(android.os.Process.myPid().toString())
        val certificate=File(noBackupFilesDir,"system-download-test-ca.pem").inputStream().use {java.security.cert.CertificateFactory.getInstance("X.509").generateCertificate(it)} as java.security.cert.X509Certificate
        val trust=okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(certificate).build()
        return okhttp3.OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
    }
}
