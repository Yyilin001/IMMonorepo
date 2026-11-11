package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class ResourceUploadEngineTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture(private val scheduler:AccountWorkScheduler?=null) {
        val diagnostics=NetworkDiagnostics()
        val actor=UserId(id());val device=DeviceId(id());var time=1000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store,scheduler=scheduler)
        val source=File.createTempFile("upload-engine-",".txt",context.cacheDir).apply { writeText("ABCDEFGHIJ") }
        val sessions=java.util.concurrent.ConcurrentHashMap<String,ResourceUploadSession>();var creates=0;var transfers=0;var finalizes=0;var statuses=0
        val intents=java.util.concurrent.CopyOnWriteArrayList<Pair<String,NetworkWorkIntent?>>()
        suspend fun record(action:String) {intents.add(action to currentCoroutineContext()[NetworkWorkIntent])}
        var createFailure: (suspend ()->Unit)?=null;var transfer: (suspend ()->Unit)?=null;var processing=false
        val control=object: ResourceUploadControl {
            override suspend fun create(request: ResourceUploadRequest): ResourceUploadSession {
                record("create");synchronized(this@Fixture) { creates++ };val value=sessions.getOrPut(request.media) { ResourceUploadSession(ResourceUploadLocator(request.usage.home(actor),id()),request.media,1,ResourceSessionState.Created,ResourceState.Pending,10000000,null,persistentListOf(),null) }
                createFailure?.invoke();return value
            }
            override suspend fun status(previous: ResourceUploadSession): ResourceUploadSession { record("status");synchronized(this@Fixture) { statuses++ };return sessions.getValue(previous.media) }
            override suspend fun target(session: ResourceUploadSession,request: ResourceUploadRequest)=ResourceTransferPlan(ResourceTransferMode.Put,"https://media.example.test/object",persistentListOf(),persistentMapOf(),null,10000000,request.byteCount,null,null,request.checksum)
            override suspend fun finalize(session: ResourceUploadSession): ResourceUploadSession { record("finalize");synchronized(this@Fixture) { finalizes++ };return session.copy(state=ResourceSessionState.Completed,resourceState=if(processing) ResourceState.Processing else ResourceState.Ready,bindableUntil=if(processing) null else 10000000).also { sessions[it.media]=it } }
            override suspend fun cancel(session: ResourceUploadSession)=session.copy(state=ResourceSessionState.Cancelled,resourceState=ResourceState.Pending,bindableUntil=null).also { sessions[it.media]=it }
        }
        fun bytes(): ResourceUploadBytes = object: ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan) { record("transfer");synchronized(this@Fixture) { transfers++ };files.withOriginal(upload=work.id) { transfer?.invoke() } }
        }
        var engine=ResourceUploadEngine(store,control,bytes(),now={ time },random={ 0.5 },diagnostics=diagnostics)
        suspend fun prepare(): ResourceUploadWork {
            val asset=files.importFile(source,"附件.txt","text/plain",ResourceUsage.UserAvatar,1024)
            return store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
        }
        suspend fun reopen() {
            engine.close();files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store,scheduler=scheduler)
            engine=ResourceUploadEngine(store,control,bytes(),now={ time },random={ 0.5 },diagnostics=diagnostics)
        }
        suspend fun close() { engine.close();files.close();store.close();source.delete() }
    }
    private suspend fun fails(block: suspend ()->Unit) { var error: Exception?=null;try { block() } catch(value: Exception) { error=value };assertNotNull(error) }
    @Test fun uploadDiagnosticsBelongToEngineAndByteCompletionRemainsUnknownUntilControlProof()=runBlocking {
        val f=Fixture();val foreign=NetworkDiagnostics()
        try {
            val work=f.prepare();f.engine.start(false)
            withContext(NetworkDiagnosticsScope(foreign)) {f.engine.resume(work.id);f.engine.resume(work.id)}
            val before=f.diagnostics.snapshot()
            assertEquals(2,before.operations.size);assertTrue(before.operations.all {it.kind==OperationKind.MediaUpload && it.action==OperationWorkAction.Submit})
            assertTrue(before.operations.all {it.certainty==NetworkMetric.Certainty.OutcomeUnknown})
            assertEquals(0L,foreign.snapshot().operationRecorded)
            f.reopen();f.engine.start(false)
            assertEquals(ResourceUploadStage.Ready,f.engine.resume(work.id).stage)
            val sample=f.diagnostics.snapshot().operations.last()
            assertEquals(OperationExecutionState.Committed,sample.observation?.execution)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
            assertEquals(2,before.operations.size)
            assertEquals(f.store.resourceUploads().single(),f.store.resourceUpload(work.id));assertNull(f.store.resourceUpload(id()))
            f.diagnostics.close();f.engine.resume(work.id);assertEquals(3L,f.diagnostics.snapshot().operationRecorded)
        } finally {f.close()}
    }

    @Test fun durableFailureClassifiesRecoveryButHealthyProcessingPollsDoNotSpendRetryTokens()=runBlocking<Unit> {
        val f=Fixture()
        try {
            f.processing=true;val work=f.prepare();f.engine.start(false)
            f.engine.resume(work.id)
            f.transfer={f.transfer=null;throw IOException("lost PUT response")};f.engine.resume(work.id)
            f.time=f.store.resourceUploads().single().execution.retryAt
            f.engine.resume(work.id);f.engine.resume(work.id);f.engine.resume(work.id)
            repeat(3) {f.time=f.store.resourceUploads().single().execution.retryAt;f.engine.resume(work.id)}
            assertEquals(listOf("create","transfer","status","transfer","finalize","status","status","status"),f.intents.map {it.first})
            assertEquals(listOf(false,false,true,true,false,false,false,false),f.intents.map {requireNotNull(it.second).isRetry})
            assertEquals(listOf(NetworkWorkPriority.Interactive,NetworkWorkPriority.Interactive,NetworkWorkPriority.Recovery,NetworkWorkPriority.Recovery,
                NetworkWorkPriority.Interactive,NetworkWorkPriority.Interactive,NetworkWorkPriority.Interactive,NetworkWorkPriority.Interactive),f.intents.map {it.second!!.priority})
        } finally {f.close()}
    }

    @Test fun lostCreateReplyRecoversFrozenRequestAcrossDatabaseReopenAndObjectConflictRequiresFinalize()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();f.createFailure={ f.createFailure=null;throw IOException("lost response") };f.engine.start(false)
            val uncertain=f.engine.resume(work.id);assertEquals(ResourceUploadAction.Create,uncertain.execution.next);assertNull(uncertain.session);assertEquals(1,uncertain.execution.attempts)
            f.time=uncertain.execution.retryAt;f.reopen();f.engine.start(false)
            val recreated=f.engine.resume(work.id);assertEquals(work.request,recreated.request);assertEquals(2,f.creates)
            f.transfer={ throw ClientFailure.Http(409) };val unverified=f.engine.resume(work.id)
            assertFalse(unverified.terminal);assertEquals(ResourceUploadAction.Finalize,unverified.execution.next)
            assertEquals(ResourceUploadStage.Ready,f.engine.resume(work.id).stage);assertEquals(1,f.finalizes);assertFalse(f.store.resourceUploads().single().sourceReleased)
        } finally { f.close() }
    }
    @Test fun failedUploadChecksStatusBeforeFreshTargetAndCannotResetTheFiveAttemptBudget()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();f.engine.start(false);f.engine.resume(work.id);f.transfer={ throw ClientFailure.Http(403) }
            val first=f.engine.resume(work.id);assertEquals(ResourceUploadAction.Status,first.execution.next);assertEquals(1,first.execution.attempts)
            f.time=first.execution.retryAt;val checked=f.engine.resume(work.id);assertEquals(ResourceUploadAction.Upload,checked.execution.next);assertEquals(2,checked.execution.attempts)
            repeat(8) {
                val current=f.store.resourceUploads().single();if(!current.execution.attention) { f.time=maxOf(f.time,current.execution.retryAt);f.engine.resume(work.id) }
            }
            val exhausted=f.store.resourceUploads().single();assertTrue(exhausted.execution.attention);assertEquals(5,exhausted.execution.attempts);assertEquals(3,f.transfers);assertEquals(2,f.statuses)
        } finally { f.close() }
    }
    @Test fun serverCooldownSurvivesExplicitRetryAndPauseNeverCreatesAnotherIdentity()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();f.createFailure={ throw ClientFailure.Http(503,retryAfter="120") };f.engine.start(false)
            val paused=f.engine.resume(work.id);assertTrue(paused.execution.attention);assertEquals(121000L,paused.execution.serverRetryAt)
            f.engine.continueUpload(work.id,true);assertEquals(121000L,f.store.resourceUploads().single().execution.retryAt)
            f.engine.resume(work.id);assertEquals(1,f.creates)
            f.engine.pause(work.id);f.time=122000;f.engine.resume(work.id);assertEquals(1,f.creates)
            f.createFailure=null;f.engine.continueUpload(work.id);assertEquals(work.request,f.engine.resume(work.id).request);assertEquals(2,f.creates)
        } finally { f.close() }
    }
    @Test fun claimTokenFencesLateWritesAndCancellationDominatesAnInflightCompletion()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();val owner=id();val first=f.store.claimResourceUpload(work.id,owner,f.time)!!
            val session=f.control.create(work.request);f.store.recoverResourceUploadClaims(id());val replacement=f.store.claimResourceUpload(work.id,id(),f.time)!!
            fails { f.store.finishResourceUpload(first,session,ResourceUploadAction.Upload,f.time) }
            f.store.finishResourceUpload(replacement,session,ResourceUploadAction.Upload,f.time)
            val uploading=f.store.claimResourceUpload(work.id,owner,f.time)!!;assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().single().execution.next)
            f.store.requestResourceUploadCancellation(work.id);f.store.finishResourceUpload(uploading,null,ResourceUploadAction.Finalize,f.time)
            val cancelled=f.store.resourceUploads().single();assertTrue(cancelled.cancellationRequested);assertEquals(ResourceUploadAction.Cancel,cancelled.execution.next);assertNull(cancelled.execution.owner)
        } finally { f.close() }
    }
    @Test fun sharedWaiterCancellationDoesNotCancelIoButEngineCloseDrainsAndReopenReconciles()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();f.engine.start(false);f.engine.resume(work.id)
            val entered=CompletableDeferred<Unit>();var drained=false
            f.transfer={ entered.complete(Unit);try { awaitCancellation() } finally { withContext(NonCancellable) { delay(50);drained=true } } }
            val waiter=launch { f.engine.resume(work.id) };entered.await();waiter.cancelAndJoin();assertFalse(drained)
            withTimeout(5000) { f.engine.close() };assertTrue(drained);assertNull(f.store.resourceUploads().single().execution.owner)
            val cancelled=f.diagnostics.snapshot().operations.last()
            assertEquals(OperationStepMetric.Completion.Cancelled,cancelled.completion);assertNull(cancelled.observation)
            assertEquals(NetworkMetric.Certainty.OutcomeUnknown,cancelled.certainty)
            assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().single().execution.next)
            f.transfer=null;f.reopen();f.engine.start(false);f.engine.resume(work.id);assertEquals(1,f.statuses)
        } finally { f.close() }
    }
    @Test fun automaticSchedulerWakesForNewTasksAndRunsAtMostTwoFlights()=runBlocking {
        val f=Fixture();try {
            val gate=CompletableDeferred<Unit>();var active=0;var peak=0
            f.createFailure={ synchronized(f) { active++;peak=maxOf(peak,active) };try { gate.await() } finally { synchronized(f) { active-- } } }
            f.engine.start();val jobs=List(3) { f.prepare() }
            withTimeout(5000) { while(synchronized(f) { active }<2) delay(10) };assertEquals(2,peak)
            gate.complete(Unit);f.createFailure=null
            withTimeout(10000) { while(f.store.resourceUploads().any { !it.terminal }) delay(20) }
            assertEquals(3,f.finalizes);assertTrue(f.store.resourceUploads().all { it.id in jobs.map { work -> work.id } && it.stage==ResourceUploadStage.Ready })
        } finally { f.close() }
    }
    @Test fun processingPollingStopsAtSixtyAndPersistsLatestSessionBeforeAttention()=runBlocking {
        val f=Fixture();try {
            f.processing=true;val work=f.prepare();f.engine.start(false)
            f.engine.resume(work.id);f.engine.resume(work.id);f.engine.resume(work.id)
            repeat(60) { val current=f.store.resourceUploads().single();f.time=current.execution.retryAt;f.engine.resume(work.id) }
            val stopped=f.store.resourceUploads().single();assertTrue(stopped.execution.attention);assertEquals(ResourceUploadError.ProcessingBudgetExhausted,stopped.execution.error)
            assertEquals(ResourceState.Processing,stopped.session!!.resourceState);assertEquals(60,stopped.execution.polls)
            f.engine.continueUpload(work.id,true);assertEquals(0,f.store.resourceUploads().single().execution.polls)
        } finally { f.close() }
    }
    @Test fun managedPartUsesExactRangeAndRetiresOnlyItsTemporaryCopy()=runBlocking {
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(uploadTransferLimit=1))
        val held=scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Upload))
        val f=Fixture(scheduler);val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverKeys=HandshakeCertificates.Builder().heldCertificate(certificate).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server=MockWebServer();server.useHttps(serverKeys.sslSocketFactory(),false);server.start()
        val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val bytes=ManagedResourceUploadBytes(f.files,ResourcePlanUploader(http));val owner=id()
        try {
            val work=f.prepare();bytes.acquire(owner)
            val hash=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest("DEFG".toByteArray()).joinToString("") { "%02x".format(it) })
            val plan=ResourceTransferPlan(ResourceTransferMode.PartPut,server.url("/part").toString(),persistentListOf(),persistentMapOf(),null,System.currentTimeMillis()+60000,4,ResourceRange(3,6),2,hash)
            val originalBytes=f.files.storageSnapshot().managedChargedBytes
            f.files.setManagedLimit(originalBytes);fails {bytes.transfer(owner,work,plan)};assertEquals(0,server.requestCount)
            f.files.setManagedLimit(originalBytes*2)
            val gate=java.util.concurrent.CountDownLatch(1)
            server.dispatcher=object:okhttp3.mockwebserver.Dispatcher() {
                override fun dispatch(request:RecordedRequest):MockResponse {gate.await(10,java.util.concurrent.TimeUnit.SECONDS);return MockResponse().setResponseCode(204)}
            }
            val transfer=async(Dispatchers.IO) {bytes.transfer(owner,work,plan)}
            try {
                withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
                assertEquals(0,server.requestCount);assertEquals(0L,scheduler.transferDiagnostics.snapshot().recorded);scheduler.release(held)
                val request=withContext(Dispatchers.IO) {server.takeRequest(5,java.util.concurrent.TimeUnit.SECONDS)}
                assertEquals("DEFG",requireNotNull(request).body.readUtf8())
                assertEquals(1,scheduler.snapshot().activeUploads)
                val active=f.files.storageSnapshot();assertTrue(active.managedChargedBytes>originalBytes);assertTrue(active.managedChargedBytes<=originalBytes*2);assertTrue(active.temporaryReservedBytes>0)
                assertEquals(0L,scheduler.transferDiagnostics.snapshot().recorded)
                gate.countDown();transfer.await()
                assertEquals(0,scheduler.snapshot().activeUploads)
                val metric=scheduler.transferDiagnostics.snapshot().samples.single()
                assertEquals(ResourceTransferMetric.Mode.MultipartUpload,metric.mode);assertEquals(4L,metric.bodyBytesSent)
                assertEquals(0L,metric.bodyBytesReceived);assertEquals(204,metric.statusCode);assertFalse(metric.failed);assertFalse(metric.cancelled)
            } finally {gate.countDown();transfer.cancelAndJoin()}
            assertEquals(originalBytes,f.files.storageSnapshot().managedChargedBytes)
            f.files.withOriginal(upload=work.id) { assertEquals("ABCDEFGHIJ",it.readText());assertTrue(File(it.parentFile!!.parentFile,"upload-parts").listFiles()!!.isEmpty()) }
        } finally { bytes.release(owner);server.close();http.dispatcher.executorService.shutdown();f.close();scheduler.release(held);scheduler.closeAndDrain() }
    }
    @Test fun legacyRowsMigrateToStatusOrCancelWithoutCreatingNewOperationIdentity()=runBlocking {
        val f=Fixture();try {
            val active=f.prepare();val cancelled=f.prepare();f.store.saveResourceUploadSession(active.id,f.control.create(active.request));f.store.requestResourceUploadCancellation(cancelled.id)
            val path=File(context.noBackupFilesDir,"im-${f.store.resourceScope}.db")
            f.engine.close();f.files.close();f.store.close()
            android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.beginTransaction();try {
                    db.execSQL("ALTER TABLE resource_uploads RENAME TO legacy_uploads")
                    db.execSQL("CREATE TABLE resource_uploads (id TEXT PRIMARY KEY,asset TEXT NOT NULL,operation TEXT UNIQUE NOT NULL,media TEXT UNIQUE NOT NULL,request TEXT NOT NULL,session TEXT,stage TEXT NOT NULL,cancelled INTEGER NOT NULL DEFAULT 0,released INTEGER NOT NULL DEFAULT 0)")
                    db.execSQL("INSERT INTO resource_uploads SELECT id,asset,operation,media,request,session,stage,cancelled,released FROM legacy_uploads")
                    db.execSQL("DROP TABLE legacy_uploads");db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            }
            f.store=SqliteClientStore(context,f.actor,f.device);f.files=ManagedResourceFiles(context,f.store);f.engine=ResourceUploadEngine(f.store,f.control,f.bytes(),now={ f.time })
            assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().first { it.id==active.id }.execution.next)
            assertEquals(ResourceUploadAction.Cancel,f.store.resourceUploads().first { it.id==cancelled.id }.execution.next)
            f.engine.start(false);assertEquals(active.request,f.engine.resume(active.id).request);assertEquals(1,f.statuses)
            assertEquals(ResourceUploadStage.Cancelled,f.engine.resume(cancelled.id).stage)
        } finally { f.close() }
    }
}
