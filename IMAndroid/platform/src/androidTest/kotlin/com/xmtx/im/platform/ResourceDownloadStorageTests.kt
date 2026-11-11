package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID

class ResourceDownloadStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun descriptor(text:String="download")=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"文件.txt","text/plain",text.length.toLong(),ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
    private suspend fun catalog(store:SqliteClientStore,vararg values:ResourceDescriptor) {
        store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(values.mapIndexed {i,value->RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-i,0,value.key.media),1000,value)}.toPersistentList(),100,null))
    }
    private suspend fun enqueue(store:SqliteClientStore,value:ResourceDescriptor)=store.enqueueResourceDownload(value.key,store.resourceSources(value.key).sources.single())
    private suspend fun row(store:SqliteClientStore,id:String)=store.resourceDownloads().first {it.work.id==id}.work
    private suspend fun until(body:suspend ()->Boolean)=withTimeout(10000) {while(!body()) delay(10)}
    private fun target(value:ResourceDescriptor,url:String="https://provider.invalid/?private=capability")=MediaDownloadTargetClient(object:AuthenticatedTransport {
        override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unexpected request")
        override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
            put("version",1);put("mode","http_get");put("url",url);put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
            put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",value.byteCount);put("checksum",value.checksum!!.payload())
        })})
    })
    private val uploads=object:ResourceUploadControl {
        override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("no upload")
        override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("no upload")
        override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("no upload")
        override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("no upload")
        override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("no upload")
    }
    @Test fun durableDownloadReportsOnlyCurrentResponseBytesThroughDetachedWriter()=runBlocking<Unit> {
        val cert=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(cert).build()
        val trust=okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server=okhttp3.mockwebserver.MockWebServer();server.useHttps(keys.sslSocketFactory(),false);server.start()
        val http=okhttp3.OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val downloader=MediaFileDownloader(http,4096);val store=store();val body="x".repeat(8192);val value=descriptor(body)
        val targets=target(value,server.url("/original").toString());val scheduler=AccountWorkScheduler()
        val activity=AccountResourceActivity(context,store,uploads,scheduler=scheduler,download=downloader::download,targets=targets)
        var run:Job?=null
        try {
            repeat(2) {index->server.enqueue(okhttp3.mockwebserver.MockResponse().setResponseCode(206)
                .setHeader("Content-Range","bytes ${index*4096}-${index*4096+4095}/8192").setHeader("ETag","\"v1\"")
                .setBody(body.substring(index*4096,index*4096+4096)).throttleBody(1024,250,java.util.concurrent.TimeUnit.MILLISECONDS))}
            catalog(store,value);val job=enqueue(store,value);val id=ResourceTransferId(ResourceTransferKind.Download,job.id)
            run=launch {activity.runForeground()}
            val snapshot=withTimeout(5000) {activity.transferWaiting.snapshots.first {it.attempts[id]?.transferredBytes in 1L..4095L}}
            val progress=snapshot.attempts[id]!!;assertEquals(4096L,progress.expectedBytes)
            val canonical=store.resourceTransfers(ResourceTransferQuery())
            val raw=canonical.entries.single {it.id==id};assertNull(raw.attemptProgress);assertEquals(8192L,raw.totalBytes)
            val projected=canonical.applyingObservations(snapshot).entries.single {it.id==id}
            assertEquals(progress,projected.attemptProgress);assertEquals(raw.confirmedBytes,projected.confirmedBytes)
            val next=withTimeout(5000) {activity.transferWaiting.snapshots.first {it.attempts[id]?.let {p->p.attemptId!=progress.attemptId && p.transferredBytes in 1..4095}==true}}
            assertEquals(4096L,next.attempts[id]!!.expectedBytes)
            until {row(store,job.id).terminal};assertEquals(ResourceDownloadPhase.Completed,row(store,job.id).phase)
            assertTrue(activity.transferWaiting.snapshots.value.attempts.isEmpty());assertEquals(2,server.requestCount)
            val metrics=scheduler.transferDiagnostics.snapshot().samples;assertEquals(2,metrics.size)
            assertTrue(metrics.all {it.mode==ResourceTransferMetric.Mode.RangeDownload && it.bodyBytesReceived==4096L && it.retryAttempt && !it.failed && !it.cancelled})
            assertTrue(metrics.all {it.verifiedRangeRebuildPrefixBytes==null})
        } finally {run?.cancelAndJoin();activity.close();scheduler.closeAndDrain();store.close();server.close();http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
    }
    @Test fun durableDownloadWaitsForSharedRetryQuotaAfterCancellationReopenAndManualReset()=runBlocking<Unit> {
        val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
        val cert=okhttp3.tls.HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverKeys=okhttp3.tls.HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientKeys=okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server=okhttp3.mockwebserver.MockWebServer();server.useHttps(serverKeys.sslSocketFactory(),false);server.start()
        val downloader=MediaFileDownloader(okhttp3.OkHttpClient.Builder().sslSocketFactory(clientKeys.sslSocketFactory(),clientKeys.trustManager).build())
        var store=store();val value=descriptor();val targets=target(value,server.url("/original").toString())
        var activity:AccountResourceActivity?=null;var run:Job?=null;var authorizations=0
        fun owner()=AccountResourceActivity(context,store,uploads,scheduler=scheduler,download=downloader::download,targets=MediaTargetResolving {media,message,size->
            val intent=requireNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(intent.isRetry)
            assertEquals(NetworkWorkPriority.Interactive,intent.priority);authorizations++;targets.resolve(media,message,size)
        })
        try {
            repeat(5) {scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download,isRetry=true)) {}}
            catalog(store,value);val job=enqueue(store,value)
            activity=owner();run=launch {activity!!.runForeground()}
            until {scheduler.snapshot().waitingByteTransfers==1}
            assertEquals(0,server.requestCount);assertEquals(1,row(store,job.id).attempts)
            assertEquals(ResourceTransferWaitingReason.ServiceCooldown,activity.transferWaiting.state.value[ResourceTransferId(ResourceTransferKind.Download,job.id)])
            scheduler.withPermit(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download)) {assertEquals(1,scheduler.snapshot().activeDownloads)}
            run.cancelAndJoin();run=null;assertTrue(activity.transferWaiting.state.value.isEmpty());activity.close();activity=null
            store.controlResourceDownload(job.id,ResourceDownloadControl.Pause);store.close();store=store()
            store.controlResourceDownload(job.id,ResourceDownloadControl.Run);assertEquals(0,row(store,job.id).attempts)
            activity=owner();run=launch {activity!!.runForeground()}
            until {scheduler.snapshot().waitingByteTransfers==1};assertEquals(0,server.requestCount)
            server.enqueue(okhttp3.mockwebserver.MockResponse().setBody("download"))
            clock.set(2000);scheduler.setDegraded(false)
            until {row(store,job.id).terminal}
            assertEquals(ResourceDownloadPhase.Completed,row(store,job.id).phase)
            assertEquals(2,authorizations);assertEquals(1,server.requestCount);assertEquals(0,scheduler.snapshot().activeDownloads);assertTrue(activity.transferWaiting.state.value.isEmpty())
        } finally {run?.cancelAndJoin();activity?.close();scheduler.closeAndDrain();store.close();server.close()}
    }
    @Test fun repeatedEnqueuePreservesSourceRetryFloorAndPausedIntentAcrossReopen()=runBlocking {
        var store=store();val a=descriptor();val b=descriptor();val now=System.currentTimeMillis()
        try {
            catalog(store,a,b);val job=enqueue(store,a);assertEquals(job.id,enqueue(store,b).id)
            val claim=store.claimResourceDownload(job.id,id(),now+1)!!
            store.releaseResourceDownload(claim,ResourceDownloadIssue.Network,now+60000,now+50000,false,now+2)
            val repeated=enqueue(store,b);assertEquals(job.message,repeated.message);assertEquals(1,repeated.attempts);assertEquals(now+60000,repeated.retryAt)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Pause)
            assertTrue(runCatching {enqueue(store,a)}.isFailure);store.close();store=store()
            assertEquals(ResourceDownloadControl.Pause,row(store,job.id).control)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Run);assertEquals(0,row(store,job.id).attempts)
            assertNull(store.claimResourceDownload(job.id,id(),now+40000));assertEquals(now+50000,row(store,job.id).serverRetryAt)
        } finally {store.close()}
    }
    @Test fun pauseWaitsForWriterDrainAndResumeObtainsFreshAuthorization()=runBlocking {
        val store=store();val value=descriptor();val started=CompletableDeferred<Unit>();val stopping=CompletableDeferred<Unit>();val drained=CompletableDeferred<Unit>()
        var transfers=0;var authorizations=0;val targets=target(value)
        val activity=AccountResourceActivity(context,store,uploads,download={_,file->
            transfers++;if(transfers==1) {started.complete(Unit);try {awaitCancellation()} finally {withContext(NonCancellable) {stopping.complete(Unit);drained.await()}}} else file.writeText("download")
        },targets=MediaTargetResolving {media,message,size->authorizations++;targets.resolve(media,message,size)})
        var run:Job?=null
        try {
            catalog(store,value);val job=enqueue(store,value);run=launch {activity.runForeground()};started.await()
            store.controlResourceDownload(job.id,ResourceDownloadControl.Pause);stopping.await()
            assertNotNull(row(store,job.id).owner);assertEquals(ResourceDownloadPhase.Running,row(store,job.id).phase)
            assertTrue(runCatching {store.controlResourceDownload(job.id,ResourceDownloadControl.Run)}.isFailure)
            drained.complete(Unit);until {row(store,job.id).owner==null}
            store.controlResourceDownload(job.id,ResourceDownloadControl.Run);until {row(store,job.id).terminal}
            assertEquals(ResourceDownloadPhase.Completed,row(store,job.id).phase);assertEquals(2,authorizations);assertEquals(2,transfers)
        } finally {drained.complete(Unit);run?.cancelAndJoin();activity.close();store.close()}
    }
    @Test fun cancellingOneTaskDoesNotCancelAnIndependentlyAuthorizedSharedReader()=runBlocking {
        val store=store();val value=descriptor();val started=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();val targets=target(value)
        val activity=AccountResourceActivity(context,store,uploads,download={_,file->started.complete(Unit);release.await();file.writeText("download")},targets=targets)
        val reader=MessageOriginalFiles(targets,store,activity.files);var run:Job?=null;var other:Deferred<String?>?=null
        try {
            catalog(store,value);val job=enqueue(store,value);run=launch {activity.runForeground()};started.await()
            other=async {reader.withOriginal(value.key) {_,file->file.readText()}}
            until {activity.files.downloadDemandCount()==2};store.controlResourceDownload(job.id,ResourceDownloadControl.Cancel)
            until {row(store,job.id).phase==ResourceDownloadPhase.Stopped};assertFalse(other.isCompleted)
            release.complete(Unit);assertEquals("download",other.await());assertEquals(ResourceDownloadPhase.Stopped,row(store,job.id).phase)
        } finally {release.complete(Unit);other?.cancelAndJoin();reader.close();run?.cancelAndJoin();activity.close();store.close()}
    }
    @Test fun publishedBytesWithAnAbandonedClaimRecoverOnlyAfterFreshAuthorization()=runBlocking {
        var store=store();val value=descriptor();var files=ManagedResourceFiles(context,store,download={_,file->file.writeText("download")});val targets=target(value)
        var activity:AccountResourceActivity?=null;var run:Job?=null
        try {
            catalog(store,value);val job=enqueue(store,value);store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!
            val read=store.selectMessageResource(value.key);files.withDownloaded(targets.resolve(value.key.media,MediaMessageLocation(room,read.source.message),null)) {}
            files.close();store.close();store=store();var authorizations=0
            activity=AccountResourceActivity(context,store,uploads,download={_,_->error("verified cache must be reused")},targets=MediaTargetResolving {media,message,size->authorizations++;targets.resolve(media,message,size)})
            run=launch {activity!!.runForeground()};until {row(store,job.id).terminal}
            assertEquals(ResourceDownloadPhase.Completed,row(store,job.id).phase);assertEquals(2,row(store,job.id).attempts);assertEquals(1,authorizations)
        } finally {run?.cancelAndJoin();activity?.close();if(activity==null) files.close();store.close()}
    }
    @Test fun revokedSourcesHideMetadataStopAdmissionAndStillAllowCancellation()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);val job=enqueue(store,value);store.unavailable(room)
            assertNull(store.claimResourceDownload(job.id,id(),System.currentTimeMillis()));assertFalse(store.resourceDownloads().single().sourceAvailable)
            assertEquals(ResourceDownloadIssue.Unavailable,row(store,job.id).issue);assertTrue(runCatching {store.controlResourceDownload(job.id,ResourceDownloadControl.Run)}.isFailure)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Cancel);assertEquals(ResourceDownloadPhase.Stopped,row(store,job.id).phase)
        } finally {store.close()}
    }
    @Test fun wallClockRollbackDoesNotPreventUserControlsOrInvalidateCompletionTime()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);val job=enqueue(store,value);val earlier=job.createdAt-1000
            store.controlResourceDownload(job.id,ResourceDownloadControl.Pause,earlier)
            assertEquals(ResourceDownloadControl.Pause,row(store,job.id).control)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Run,earlier)
            assertTrue(row(store,job.id).requested)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Cancel,earlier)
            assertEquals(ResourceDownloadPhase.Stopped,row(store,job.id).phase)
            assertEquals(job.createdAt,row(store,job.id).finishedAt)
        } finally {store.close()}
    }
    @Test fun staleClaimsCannotOverwriteNewOwnersOrRecoveredCancellation()=runBlocking {
        val store=store();val value=descriptor();val now=System.currentTimeMillis()
        try {
            catalog(store,value);val job=enqueue(store,value);val a=store.claimResourceDownload(job.id,id(),now+1)!!;val owner=id()
            store.recoverResourceDownloads(owner,now+2);val b=store.claimResourceDownload(job.id,owner,now+3)!!
            store.releaseResourceDownload(a,ResourceDownloadIssue.Network,now+5000,now+5000,false,now+4);assertEquals(b.work,row(store,job.id))
            store.controlResourceDownload(job.id,ResourceDownloadControl.Cancel);store.recoverResourceDownloads(id(),now+5)
            store.completeResourceDownload(b,store.selectMessageResource(value.key),now+6)
            assertEquals(ResourceDownloadPhase.Stopped,row(store,job.id).phase)
        } finally {store.close()}
    }
    @Test fun fiveAttemptBudgetAndActiveCapacityCannotBeResetByRepeatedClicks()=runBlocking {
        val store=store();val values=(0..16).map {descriptor("content-$it")};val now=System.currentTimeMillis()
        try {
            catalog(store,*values.toTypedArray());val jobs=values.take(16).map {enqueue(store,it)}
            assertTrue(runCatching {enqueue(store,values.last())}.isFailure)
            val job=jobs.first()
            for(attempt in 1..5) {
                val claim=store.claimResourceDownload(job.id,id(),now+attempt*100L)!!
                store.releaseResourceDownload(claim,ResourceDownloadIssue.Network,now+attempt*100L+1,0,false,now+attempt*100L)
            }
            assertEquals(5,enqueue(store,values.first()).attempts);assertFalse(row(store,job.id).requested)
            assertNull(store.claimResourceDownload(job.id,id(),now+10000))
            store.controlResourceDownload(job.id,ResourceDownloadControl.Cancel);assertNotNull(enqueue(store,values.last()))
        } finally {store.close()}
    }
    @Test fun completionRequiresBothPublishedBytesAndCurrentMessageAuthority()=runBlocking {
        val store=store();val value=descriptor();val files=ManagedResourceFiles(context,store,download={_,file->file.writeText("download")})
        try {
            catalog(store,value);val job=enqueue(store,value);val claim=store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!
            val evidence=store.selectMessageResource(value.key)
            assertTrue(runCatching {store.completeResourceDownload(claim,evidence,System.currentTimeMillis())}.isFailure)
            files.withDownloaded(target(value).resolve(value.key.media,claim.work.message,null)) {}
            store.unavailable(room)
            assertTrue(runCatching {store.completeResourceDownload(claim,evidence,System.currentTimeMillis())}.isFailure)
            store.releaseResourceDownload(claim,ResourceDownloadIssue.Unavailable,null,0,false,System.currentTimeMillis())
            assertFalse(row(store,job.id).terminal);assertFalse(row(store,job.id).requested)
        } finally {files.close();store.close()}
    }
    @Test fun policyRestrictedTaskWaitsForExplicitRetryAndDoesNotRedownloadOnSettingsChange()=runBlocking {
        val store=store();val value=descriptor();var calls=0
        val activity=AccountResourceActivity(context,store,uploads,download={_,file->
            calls++;if(!store.downloadNetworkPreferences().allowsCellular) throw ResourceDownloadPolicyRestricted()
            file.writeText("download")
        },targets=target(value))
        var run:Job?=null
        try {
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,false))
            catalog(store,value);val job=enqueue(store,value);run=launch {activity.runForeground()}
            until {row(store,job.id).issue==ResourceDownloadIssue.Policy && row(store,job.id).owner==null}
            assertFalse(row(store,job.id).requested);assertEquals(1,calls)
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,false))
            assertFalse(row(store,job.id).requested)
            store.controlResourceDownload(job.id,ResourceDownloadControl.Run)
            until {row(store,job.id).terminal}
            assertEquals(ResourceDownloadPhase.Completed,row(store,job.id).phase);assertEquals(2,calls)
        } finally {run?.cancelAndJoin();activity.close();store.close()}
    }

}
