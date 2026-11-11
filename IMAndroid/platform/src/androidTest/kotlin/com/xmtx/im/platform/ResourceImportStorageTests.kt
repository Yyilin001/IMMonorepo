package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class ResourceImportStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private suspend fun fails(body: suspend ()->Unit) { assertNotNull(runCatching { body() }.exceptionOrNull()) }
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device)
        fun request(usage: ResourceUsage=ResourceUsage.UserAvatar)=ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),usage,id())
        suspend fun prepare(request: ResourceImportRequest=request())=store.prepareResourceImport(id(),request,now)
        suspend fun work(id: String)=store.resourceImports().first { it.id==id }
        fun status(work: ResourceImportWork,state: ResourceImportState=ResourceImportState.Ready)=ResourceImportStatus(work.request.locator(actor),work.request.targetMedia,state,if(state==ResourceImportState.Ready) now+60000 else null)
        suspend fun reopen() { store.close();store=SqliteClientStore(context,actor,device) }
    }
    @Test fun frozenRequestsAndClaimsSurviveReopenAndStaleOwnersCannotPublish()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();assertEquals(work,f.store.prepareResourceImport(work.id,work.request,f.now+1))
            fails { f.store.prepareResourceImport(work.id,work.request.copy(operation=id()),f.now) }
            fails { f.prepare(work.request.copy(targetMedia=id())) };fails { f.prepare(work.request.copy(operation=id())) }
            val old=f.store.claimResourceImport(work.id,id(),f.now)!!;f.reopen()
            assertEquals(old.work,f.work(work.id));val owner=id();f.store.recoverResourceImportClaims(owner)
            val recovered=f.work(work.id);assertEquals(1,recovered.execution.attempts);assertNull(recovered.execution.owner);assertEquals(old.work.execution.deadline,recovered.execution.deadline)
            assertNull(f.store.claimResourceImport(work.id,owner,f.now));f.now=recovered.execution.retryAt
            val fresh=f.store.claimResourceImport(work.id,owner,f.now)!!;f.store.finishResourceImport(old,f.status(work),f.now);assertNull(f.work(work.id).status)
            fails { f.store.finishResourceImport(fresh,f.status(work).copy(media=id()),f.now) }
            fails { f.store.finishResourceImport(fresh,f.status(work).copy(locator=ResourceImportLocator(ResourceHome.Account(UserId(id())),work.request.operation)),f.now) }
            f.store.finishResourceImport(fresh,f.status(work),f.now);val done=f.work(work.id);assertTrue(done.bindable(f.now));assertEquals(done,f.store.snapshot().resourceImports.single())
            f.store.releaseResourceImport(work.id);f.reopen();assertFalse(f.work(work.id).retained)
        } finally { f.store.close() }
    }
    @Test fun lostCreateReplyRecoversFromDerivedLocatorWithoutReadingSourceOrCreatingNewMedia()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();var remote: ResourceImportStatus?=null;var creates=0;var lookups=0
            val control=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus { creates++;assertEquals(work.request,request);remote=f.status(work);throw IOException("lost reply") }
                override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus { lookups++;assertEquals(work.request.locator(f.actor),locator);return remote ?: throw ClientFailure.Http(404) }
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus=error("unexpected cancellation")
            }
            ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce();val unknown=f.work(work.id);assertNull(unknown.status);assertFalse(unknown.execution.attention)
            f.reopen();f.now=unknown.execution.retryAt;ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce()
            assertTrue(f.work(work.id).bindable(f.now));assertEquals(1,creates);assertEquals(2,lookups);assertEquals(work.request,f.work(work.id).request)
        } finally { f.store.close() }
    }
    @Test fun cancellationRacingReadyMustWaitForOriginalCancelResultAndNeverBecomesBindable()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();val claim=f.store.claimResourceImport(work.id,id(),f.now)!!
            f.store.cancelResourceImport(work.id);f.store.finishResourceImport(claim,f.status(work),f.now)
            var pending=f.work(work.id);assertFalse(pending.terminal);assertFalse(pending.bindable(f.now));assertFalse(pending.cancellationResolved)
            fails { f.store.releaseResourceImport(work.id) };f.reopen();var cancels=0
            val control=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("must not create")
                override suspend fun status(locator: ResourceImportLocator)=f.status(work)
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus { cancels++;throw ClientFailure.Http(404) }
            }
            ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce();pending=f.work(work.id)
            assertFalse(pending.terminal);assertTrue(pending.execution.attention);assertFalse(pending.cancellationResolved)
            f.store.controlResourceImport(work.id,false,true)
            val actual=object: ResourceImportControl by control { override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus { cancels++;return f.status(work) } }
            ResourceImportService(f.actor,f.store,actual) { f.now }.recoverOnce();val done=f.work(work.id)
            assertTrue(done.terminal);assertTrue(done.cancellationResolved);assertEquals(ResourceImportState.Ready,done.status!!.state);assertFalse(done.bindable(f.now));assertEquals(2,cancels)
        } finally { f.store.close() }
    }
    @Test fun savedStatus404IsNotPermissionToCreateAgain()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();val claim=f.store.claimResourceImport(work.id,id(),f.now)!!;f.store.finishResourceImport(claim,f.status(work,ResourceImportState.Copying),f.now)
            f.now=f.work(work.id).execution.retryAt;var creates=0
            val control=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus { creates++;return f.status(work) }
                override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus=throw ClientFailure.Http(404)
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus=error("unexpected")
            }
            ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce();assertEquals(0,creates);assertTrue(f.work(work.id).execution.attention);assertEquals(ResourceImportState.Copying,f.work(work.id).status!!.state)
        } finally { f.store.close() }
    }
    @Test fun serverRetryFloorSurvivesPauseCancellationExplicitRetryAndReopen()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();val floor=f.now+120000;val claim=f.store.claimResourceImport(work.id,id(),f.now)!!
            f.store.failResourceImport(claim,ResourceImportIssue.Transport,null,floor)
            f.store.controlResourceImport(work.id,true);f.store.cancelResourceImport(work.id);f.store.controlResourceImport(work.id,false,true);f.reopen()
            assertEquals(floor,f.work(work.id).execution.serverRetryAt);assertNull(f.store.claimResourceImport(work.id,id(),floor-1))
            assertNotNull(f.store.claimResourceImport(work.id,id(),floor))
        } finally { f.store.close() }
    }
    @Test fun fifthUnknownAttemptAndExpiredRoundRequireExplicitRetry()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();var latest: ResourceImportClaim?=null
            repeat(5) { index ->
                latest=f.store.claimResourceImport(work.id,id(),f.now)!!;assertEquals(index+1,latest!!.work.execution.attempts)
                if(index<4) { f.store.failResourceImport(latest!!,ResourceImportIssue.Transport,f.now+1);f.now++ }
            }
            f.reopen();f.store.recoverResourceImportClaims(id());assertTrue(f.work(work.id).execution.attention);assertNull(f.store.claimResourceImport(work.id,id(),f.now+60000))
            f.store.controlResourceImport(work.id,false,true);val fresh=f.store.claimResourceImport(work.id,id(),f.now)!!
            f.store.failResourceImport(fresh,ResourceImportIssue.Unknown,f.now+1);f.now=fresh.work.execution.deadline!!
            assertNull(f.store.claimResourceImport(work.id,id(),f.now));assertEquals(ResourceImportIssue.BudgetExhausted,f.work(work.id).execution.issue)
        } finally { f.store.close() }
    }
    @Test fun successfulNonterminalPollingHasDurableSixtyPollBudget()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare()
            repeat(60) { index ->
                val claim=f.store.claimResourceImport(work.id,id(),f.now)!!;f.store.finishResourceImport(claim,f.status(work,ResourceImportState.Processing),f.now)
                val current=f.work(work.id);assertEquals(index+1,current.execution.polls);assertEquals(index==59,current.execution.attention);f.now=current.execution.retryAt
                if(index==30) f.reopen()
            }
            assertEquals(ResourceImportIssue.PollingExhausted,f.work(work.id).execution.issue);assertNull(f.store.claimResourceImport(work.id,id(),f.now))
            f.store.controlResourceImport(work.id,false,true);assertNotNull(f.store.claimResourceImport(work.id,id(),f.now))
        } finally { f.store.close() }
    }
    @Test fun uploadsAndImportsShareThirtyTwoAdmissionSlotsInBothDirections()=runBlocking {
        val f=Fixture();val files=ManagedResourceFiles(context,f.store);val source=File.createTempFile("import-capacity-",".txt",context.filesDir).apply { writeText("shared capacity") }
        suspend fun asset()=files.importFile(source,"附件.txt","text/plain",ResourceUsage.UserAvatar,1024)
        fun request(asset: ResourceLocalAsset)=ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,modes=persistentListOf(ResourceTransferMode.Put),displayName=asset.displayName)
        try {
            val first=asset();f.store.prepareResourceUpload(id(),first.id,request(first));val imports=mutableListOf<ResourceImportWork>()
            repeat(31) { imports+=f.prepare() };fails { f.prepare() }
            val extra=asset();fails { f.store.prepareResourceUpload(id(),extra.id,request(extra)) };assertTrue(f.store.resourceAssets().first { it.id==extra.id }.selectionActive)
            val done=imports.first();val claim=f.store.claimResourceImport(done.id,id(),f.now)!!;f.store.finishResourceImport(claim,f.status(done,ResourceImportState.Failed),f.now)
            f.store.prepareResourceUpload(id(),extra.id,request(extra));fails { f.prepare() }
            assertEquals(2,f.store.resourceUploads().size);assertEquals(31,f.store.resourceImports().size)
        } finally { files.close();f.store.close();source.delete() }
    }
    @Test fun foregroundKeepsTwoPhysicalSlotsUntilCancellationActuallyDrains()=runBlocking {
        val f=Fixture();val entered=AtomicInteger();val live=AtomicInteger();val max=AtomicInteger();val release=CompletableDeferred<Unit>();val stopped=CompletableDeferred<Unit>()
        var runner: Job?=null
        try {
            repeat(3) { f.prepare() }
            val control=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("unexpected")
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus=error("unexpected")
                override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus {
                    entered.incrementAndGet();val current=live.incrementAndGet();max.updateAndGet { maxOf(it,current) }
                    try { awaitCancellation() } finally { stopped.complete(Unit);withContext(NonCancellable) { release.await() };live.decrementAndGet() }
                }
            }
            runner=launch { ResourceImportService(f.actor,f.store,control) { f.now }.runForeground() }
            withTimeout(5000) { while(entered.get()<2) delay(10) }
            val active=f.store.resourceImports().first { it.execution.owner!=null };f.store.controlResourceImport(active.id,true);withTimeout(5000) { stopped.await() };delay(100)
            assertEquals(2,entered.get());assertEquals(2,live.get());runner.cancel();delay(100);assertFalse(runner.isCompleted)
            release.complete(Unit);withTimeout(5000) { runner.join() };assertEquals(0,live.get());assertEquals(2,max.get());assertTrue(f.store.resourceImports().all { it.execution.owner==null })
        } finally { release.complete(Unit);runner?.cancelAndJoin();f.store.close() }
    }
    @Test fun servicePersistsServerCooldownAndInvalidResponsesCannotAdvanceLogicalState()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();var calls=0
            val throttled=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("unexpected create")
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus=error("unexpected cancel")
                override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus { calls++;throw ClientFailure.Http(429,retryAfter="120") }
            }
            ResourceImportService(f.actor,f.store,throttled) { f.now }.recoverOnce()
            val delayed=f.work(work.id);assertEquals(f.now+120000,delayed.execution.serverRetryAt);assertTrue(delayed.execution.attention);assertEquals(1,calls)
            f.store.controlResourceImport(work.id,false,true);ResourceImportService(f.actor,f.store,throttled) { f.now }.recoverOnce();assertEquals(1,calls)
            f.reopen();f.now=delayed.execution.serverRetryAt
            val invalid=object: ResourceImportControl by throttled { override suspend fun status(locator: ResourceImportLocator)=f.status(work).copy(media=id()) }
            ResourceImportService(f.actor,f.store,invalid) { f.now }.recoverOnce();val rejected=f.work(work.id)
            assertNull(rejected.status);assertTrue(rejected.execution.attention);assertEquals(ResourceImportIssue.InvalidResponse,rejected.execution.issue);assertEquals(work.request,rejected.request)
        } finally { f.store.close() }
    }

    @Test fun cancellationConflictRequiresFreshTerminalStatusAndKeepsOriginalUnbindable()=runBlocking {
        val f=Fixture();try {
            val work=f.prepare();f.store.cancelResourceImport(work.id);var ready=false;var reads=0;var cancels=0
            val control=object: ResourceImportControl {
                override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("unexpected create")
                override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus { reads++;return f.status(work,if(ready) ResourceImportState.Ready else ResourceImportState.Copying) }
                override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus { cancels++;throw ClientFailure.Http(409) }
            }
            ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce();val uncertain=f.work(work.id)
            assertNull(uncertain.status);assertTrue(uncertain.execution.attention);assertFalse(uncertain.cancellationResolved);assertEquals(2,reads)
            ready=true;f.store.controlResourceImport(work.id,false,true);ResourceImportService(f.actor,f.store,control) { f.now }.recoverOnce()
            val complete=f.work(work.id);assertTrue(complete.terminal);assertTrue(complete.cancellationResolved);assertEquals(ResourceImportState.Ready,complete.status!!.state);assertFalse(complete.bindable(f.now));assertEquals(4,reads);assertEquals(2,cancels)
        } finally { f.store.close() }
    }

}
