package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class BackgroundUploadJournalTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        val source=File.createTempFile("background-journal-",".txt",context.cacheDir).apply {writeText("0123456789")}
        suspend fun prepare():ResourceUploadClaim {
            val asset=files.importFile(source,"记录.txt","text/plain",ResourceUsage.Attachment(room),1024)
            val work=store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut),asset.displayName))
            val owner=id();val create=store.claimResourceUpload(work.id,owner,now)!!
            val remote=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),work.request.media,1,ResourceSessionState.Created,ResourceState.Pending,10_000_000,null,persistentListOf(),null)
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
                    put("version",1);put("mode",if(parts) "http_part_put" else "http_put");put("url","https://objects.example.test/private?cap=NEVER-PERSIST-THIS")
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
    private fun success(mapping:ResourceBackgroundUploadMapping)=ResourceBackgroundUploadResult(mapping.id,mapping.task,204,null,mapping.expectedBytes,mapping.originDigest)
    @Test fun schedulerWaitsWithoutClaimingTasksOwnedByTheSystem()=runBlocking {
        val f=Fixture();var engine:ResourceUploadEngine?=null
        try {
            f.install(f.prepare());val observed=CompletableDeferred<Unit>();val claims=java.util.concurrent.atomic.AtomicInteger()
            val journal=object:ResourceUploadJournal by f.store {
                override suspend fun resourceUploads():PersistentList<ResourceUploadWork> = f.store.resourceUploads().also {observed.complete(Unit)}
                override suspend fun claimResourceUpload(id:String,owner:String,now:Long):ResourceUploadClaim? {
                    claims.incrementAndGet();return f.store.claimResourceUpload(id,owner,now)
                }
            }
            val control=object:ResourceUploadControl {
                override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("unexpected create")
                override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("unexpected status")
                override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("unexpected target")
                override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("unexpected finalize")
                override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("unexpected cancel")
            }
            val bytes=object:ResourceUploadBytes {
                override suspend fun acquire(owner:String) {}
                override suspend fun release(owner:String) {}
                override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan)=error("unexpected transfer")
            }
            engine=ResourceUploadEngine(journal,control,bytes,{f.now});engine.start()
            withTimeout(5000) {observed.await()};delay(100)
            assertEquals(0,claims.get());assertEquals(ResourceEngineState.Running,engine.state.value)
        } finally {engine?.close();f.close()}
    }
    @Test fun reopenKeepsExactMappingAndSourceWhileForegroundClaimsRemainExcluded()=runBlocking {
        val f=Fixture()
        try {
            val claim=f.prepare();val mapping=f.install(claim).single();val session=f.store.backgroundUploadSession()
            assertFalse(mapping.payload().toString().contains("NEVER-PERSIST-THIS"));assertFalse(mapping.payload().toString().contains("https://"))
            f.reopen();assertEquals(session,f.store.backgroundUploadSession());assertEquals(listOf(mapping),f.store.activeBackgroundUploads())
            f.store.recoverResourceUploadClaims(id());assertNull(f.store.claimResourceUpload(claim.work.id,id(),f.now))
            assertTrue(f.store.retireResourceFiles(persistentSetOf()).isEmpty())
            f.files.withOriginal(upload=claim.work.id) {assertEquals(f.source.readText(),it.readText())}
            assertTrue(runCatching {f.store.saveResourceUploadSession(claim.work.id,claim.work.session!!)}.isFailure)
            assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping),f.now))
            val work=f.store.resourceUploads().single();assertFalse(work.terminal);assertFalse(work.execution.backgroundPending)
            assertEquals(ResourceUploadAction.Finalize,work.execution.next);assertEquals(claim.work.session,work.session)
            assertFalse(f.store.completeBackgroundUpload(mapping,success(mapping),f.now));assertNotNull(f.store.claimResourceUpload(work.id,id(),f.now))
        } finally {f.close()}
    }
    @Test fun cancelledBatchWaitsForEveryPhysicalTaskBeforeRemoteCancellationCanRun()=runBlocking {
        val f=Fixture()
        try {
            val claim=f.prepare();val mappings=f.install(claim,true);f.store.requestResourceUploadCancellation(claim.work.id)
            assertTrue(f.store.completeBackgroundUpload(mappings.first(),null,f.now));f.reopen()
            assertEquals(listOf(mappings.last()),f.store.activeBackgroundUploads());assertNull(f.store.claimResourceUpload(claim.work.id,id(),f.now))
            assertTrue(f.store.resourceUploads().single().execution.backgroundPending)
            assertTrue(f.store.completeBackgroundUpload(mappings.last(),success(mappings.last()),f.now))
            val work=f.store.resourceUploads().single();assertTrue(work.cancellationRequested);assertFalse(work.terminal);assertEquals(ResourceUploadAction.Cancel,work.execution.next)
            assertEquals(0,work.execution.backgroundAttempts);assertFalse(work.execution.attention)
            assertNotNull(f.store.claimResourceUpload(claim.work.id,id(),f.now))
        } finally {f.close()}
    }
    @Test fun pauseWaitsForDrainAndResumeReconcilesStatusInsteadOfTreatingReceiptAsReady()=runBlocking {
        val f=Fixture()
        try {
            val claim=f.prepare();val mapping=f.install(claim).single();f.store.controlResourceUpload(claim.work.id,true)
            val before=ResourceTransferProjection.upload(f.store.resourceUploads().single(),1,false,f.now)
            assertEquals(ResourceTransferPhase.Pausing,before.phase);assertFalse(ResourceTransferAction.Resume in before.actions)
            assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping),f.now))
            val work=f.store.resourceUploads().single();assertTrue(work.execution.userPaused);assertEquals(ResourceUploadAction.Status,work.execution.next);assertNull(f.store.claimResourceUpload(work.id,id(),f.now))
            f.store.controlResourceUpload(work.id,false);assertEquals(ResourceUploadAction.Status,f.store.claimResourceUpload(work.id,id(),f.now)!!.work.execution.next)
        } finally {f.close()}
    }
    @Test fun mismatchedLateAndCrossAccountCallbacksCannotConsumeAnActiveMapping()=runBlocking {
        val f=Fixture();val other=Fixture()
        try {
            val claim=f.prepare();val mapping=f.install(claim).single()
            assertFalse(other.store.completeBackgroundUpload(mapping,success(mapping),f.now))
            assertFalse(f.store.completeBackgroundUpload(mapping.copy(task=id()),success(mapping),f.now))
            assertFalse(f.store.completeBackgroundUpload(mapping,success(mapping).copy(mapping=id()),f.now))
            assertFalse(f.store.completeBackgroundUpload(mapping,success(mapping).copy(task=id()),f.now))
            assertEquals(listOf(mapping),f.store.activeBackgroundUploads())
            assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping).copy(originDigest="0".repeat(64),retryNotBefore=Long.MAX_VALUE),f.now))
            val work=f.store.resourceUploads().single();assertEquals(ResourceUploadAction.Status,work.execution.next);assertEquals(1,work.execution.backgroundAttempts)
            assertEquals(0L,work.execution.serverRetryAt);assertFalse(work.terminal)
        } finally {other.close();f.close()}
    }
    @Test fun wholeConflictRequestsFinalizeButNoCallbackPublishesReadyOrPartReceipts()=runBlocking {
        val f=Fixture()
        try {
            val whole=f.prepare();val mapping=f.install(whole).single()
            assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping).copy(status=409,sentBytes=0),f.now))
            assertEquals(ResourceUploadAction.Finalize,f.store.resourceUploads().single().execution.next);assertFalse(f.store.resourceUploads().single().terminal)
            val part=f.prepare();val mappings=f.install(part,true);mappings.forEach {assertTrue(f.store.completeBackgroundUpload(it,success(it),f.now))}
            val work=f.store.resourceUploads().first {it.id==part.work.id};assertEquals(ResourceUploadAction.Status,work.execution.next);assertTrue(work.session!!.parts.isEmpty());assertFalse(work.terminal)
        } finally {f.close()}
    }
    @Test fun unknownRoundsHaveBoundedAttentionBudgetAndPreserveServerRetryFloor()=runBlocking {
        val f=Fixture()
        try {
            var claim=f.prepare();val upload=claim.work.id
            repeat(5) {round->
                val mapping=f.install(claim).single();val floor=f.now+50000
                assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping).copy(status=429,sentBytes=0,retryNotBefore=floor),f.now))
                val work=f.store.resourceUploads().single();assertEquals(round+1,work.execution.backgroundAttempts);assertEquals(floor,work.execution.serverRetryAt)
                assertTrue(work.execution.retryAt>=floor);assertNull(f.store.claimResourceUpload(upload,id(),floor-1))
                if(round<4) claim=f.next(upload) else {assertTrue(work.execution.attention);assertEquals(ResourceUploadError.BackgroundOutcomeUnknown,work.execution.error)}
            }
            val floor=f.store.resourceUploads().single().execution.serverRetryAt
            f.store.controlResourceUpload(upload,false,true);val reset=f.store.resourceUploads().single()
            assertEquals(0,reset.execution.backgroundAttempts);assertFalse(reset.execution.attention);assertEquals(floor,reset.execution.retryAt)
        } finally {f.close()}
    }
    @Test fun failedBatchInstallationRollsBackAllRowsAndKeepsTheOriginalClaim()=runBlocking {
        val f=Fixture()
        try {
            val initial=f.prepare();val old=f.install(initial).single()
            val next=f.prepare();val registrations=f.registrations(next,true)
            assertTrue(runCatching {f.store.installBackgroundUploads(next,persistentListOf(registrations.first(),registrations.last().copy(task=old.task)),f.now)}.isFailure)
            assertEquals(listOf(old),f.store.activeBackgroundUploads());val work=f.store.resourceUploads().first {it.id==next.work.id}
            assertEquals(next.owner,work.execution.owner);assertEquals(next.token,work.execution.token);assertFalse(work.execution.backgroundPending)
            f.store.finishResourceUpload(next,null,ResourceUploadAction.Status,f.now)
        } finally {f.close()}
    }
    @Test fun activeCapacityIsBoundedAndRecoverableAfterDrain()=runBlocking {
        val f=Fixture()
        try {
            val mappings=buildList {repeat(16) {add(f.install(f.prepare()).single())}}
            val pending=f.prepare();val registrations=f.registrations(pending)
            assertTrue(runCatching {f.store.installBackgroundUploads(pending,registrations,f.now)}.isFailure);assertEquals(16,f.store.activeBackgroundUploads().size)
            assertTrue(f.store.completeBackgroundUpload(mappings.first(),success(mappings.first()),f.now))
            assertEquals(1,f.store.installBackgroundUploads(pending,registrations,f.now).size);assertEquals(16,f.store.activeBackgroundUploads().size)
        } finally {f.close()}
    }
    @Test fun completedSiblingIsRetainedUntilItsBatchDrainsDespiteTombstonePruning()=runBlocking {
        val f=Fixture()
        try {
            val waiting=f.prepare();val mappings=f.install(waiting,true)
            assertTrue(f.store.completeBackgroundUpload(mappings.first(),null,f.now))
            var other=f.prepare();var first:ResourceBackgroundUploadMapping?=null
            repeat(130) {round->
                val mapping=f.install(other).single();if(round==0) first=mapping
                assertTrue(f.store.completeBackgroundUpload(mapping,success(mapping),f.now))
                other=f.next(other.work.id);f.now++
            }
            f.store.finishResourceUpload(other,null,ResourceUploadAction.Status,f.now)
            assertFalse(f.store.completeBackgroundUpload(first!!,success(first!!),f.now))
            f.reopen();assertTrue(f.store.completeBackgroundUpload(mappings.last(),success(mappings.last()),f.now))
            val work=f.store.resourceUploads().first {it.id==waiting.work.id};assertEquals(1,work.execution.backgroundAttempts);assertFalse(work.execution.backgroundPending)
        } finally {f.close()}
    }
}
