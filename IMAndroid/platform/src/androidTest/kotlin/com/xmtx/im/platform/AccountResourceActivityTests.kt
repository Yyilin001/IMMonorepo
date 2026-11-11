package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class AccountResourceActivityTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val store=SqliteClientStore(context,actor,device)
        val source=File.createTempFile("resource-activity-",".txt",context.cacheDir).apply { writeText("account foreground bytes") }
        var session: ResourceUploadSession?=null;var statuses=0
        val control=object: ResourceUploadControl {
            override suspend fun create(request: ResourceUploadRequest)=session ?: ResourceUploadSession(ResourceUploadLocator(ResourceHome.Account(actor),id()),request.media,1,ResourceSessionState.Created,ResourceState.Pending,System.currentTimeMillis()+600000,null,persistentListOf(),null).also { session=it }
            override suspend fun status(previous: ResourceUploadSession): ResourceUploadSession { statuses++;return session!! }
            override suspend fun target(session: ResourceUploadSession,request: ResourceUploadRequest)=ResourceTransferPlan(ResourceTransferMode.Put,"https://media.example.test/file",persistentListOf(),persistentMapOf(),null,System.currentTimeMillis()+60000,request.byteCount,null,null,request.checksum)
            override suspend fun finalize(session: ResourceUploadSession)=session.copy(state=ResourceSessionState.Completed,resourceState=ResourceState.Ready,bindableUntil=System.currentTimeMillis()+600000).also { this@Fixture.session=it }
            override suspend fun cancel(session: ResourceUploadSession)=session.copy(state=ResourceSessionState.Cancelled).also { this@Fixture.session=it }
        }
        suspend fun prepare(activity: AccountResourceActivity): ResourceUploadWork {
            val asset=activity.files.importFile(source,"附件.txt","text/plain",ResourceUsage.UserAvatar,1024)
            return store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
        }
    }
    @Test fun backgroundDrainsTransferAndForegroundRestartsFromAuthoritativeStatus()=runBlocking {
        val scheduler=AccountWorkScheduler();val f=Fixture();val entered=CompletableDeferred<Unit>();var blocking=true;var drained=false
        val activity=AccountResourceActivity(context,f.store,f.control,scheduler=scheduler) { files -> object: ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan) {
                files.withOriginal(upload=work.id) { file ->
                    assertEquals(f.source.readText(),file.readText())
                    if(blocking) { entered.complete(Unit);try { awaitCancellation() } finally { withContext(NonCancellable) { delay(30);drained=true } } }
                }
            }
        } }
        try {
            val work=f.prepare(activity);var snapshot=persistentListOf<ResourceUploadWork>()
            val first=launch { activity.runForeground { snapshot=it } };withTimeout(5000) { entered.await() }
            withTimeout(5000) { first.cancelAndJoin() };assertTrue(drained)
            val paused=f.store.resourceUploads().single();assertNull(paused.execution.owner);assertEquals(ResourceUploadAction.Status,paused.execution.next)
            activity.files.withOriginal(upload=work.id) { assertTrue(it.exists()) }
            blocking=false;val second=launch { activity.runForeground { snapshot=it } }
            withTimeout(5000) { while(snapshot.none { it.stage==ResourceUploadStage.Ready }) delay(10) }
            assertEquals(work.request,snapshot.single().request);assertEquals(1,f.statuses)
            withTimeout(5000) {while(scheduler.networkDiagnostics.snapshot().operations.none {it.observation?.execution==OperationExecutionState.Committed}) delay(10)}
            assertTrue(scheduler.networkDiagnostics.snapshot().operations.any {it.completion==OperationStepMetric.Completion.Cancelled && it.observation==null})
            second.cancelAndJoin()
            assertFalse(f.store.resourceUploads().single().sourceReleased)
        } finally { activity.close();scheduler.closeAndDrain();f.store.close();f.source.delete() }
    }
    @Test fun accountCloseWaitsForPhysicalDrainBeforeDatabaseMayClose()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val draining=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val activity=AccountResourceActivity(context,f.store,f.control) { files -> object: ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner: String,work: ResourceUploadWork,plan: ResourceTransferPlan) {
                files.withOriginal(upload=work.id) { entered.complete(Unit);try { awaitCancellation() } finally { withContext(NonCancellable) { draining.complete(Unit);finish.await();assertTrue(it.exists()) } } }
            }
        } }
        try {
            f.prepare(activity);val running=launch { activity.runForeground() };withTimeout(5000) { entered.await() }
            val closing=launch { activity.close();f.store.close() };withTimeout(5000) { draining.await() }
            assertFalse(closing.isCompleted);assertEquals(1,f.store.resourceUploads().size)
            finish.complete(Unit);withTimeout(5000) { closing.join();running.join() }
            assertTrue(runCatching { f.store.resourceUploads() }.isFailure)
        } finally { finish.complete(Unit);activity.close();f.store.close();f.source.delete() }
    }
    @Test fun cancellationDuringOwnershipHandoffCannotLeakOrOverlapForegroundGenerations()=runBlocking {
        val f=Fixture();val acquired=CompletableDeferred<Unit>();val handoff=CompletableDeferred<Unit>();var first=true
        val activity=AccountResourceActivity(context,f.store,f.control) { files ->
            val delegate=ManagedResourceUploadBytes(files)
            object: ResourceUploadBytes by delegate {
                override suspend fun acquire(owner: String) { delegate.acquire(owner);if(first) { first=false;acquired.complete(Unit);handoff.await() } }
            }
        }
        try {
            val initial=launch { activity.runForeground() };withTimeout(5000) { acquired.await() };initial.cancel();assertFalse(initial.isCompleted)
            handoff.complete(Unit);withTimeout(5000) { initial.join() }
            val observed=CompletableDeferred<Unit>();val next=launch { activity.runForeground { observed.complete(Unit) } }
            withTimeout(5000) { observed.await() }
            assertTrue(runCatching { activity.runForeground() }.exceptionOrNull() is IllegalStateException)
            next.cancelAndJoin();activity.close()
            assertTrue(runCatching { activity.runForeground() }.exceptionOrNull() is IllegalStateException)
        } finally { handoff.complete(Unit);activity.close();f.store.close();f.source.delete() }
    }
    @Test fun importCancellationDrainsBeforeAccountFileOwnershipAndDatabaseAreReleased()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val draining=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val control=object: ResourceImportControl {
            override suspend fun create(request: ResourceImportRequest): ResourceImportStatus=error("unexpected create")
            override suspend fun cancel(locator: ResourceImportLocator): ResourceImportStatus=error("unexpected cancel")
            override suspend fun status(locator: ResourceImportLocator): ResourceImportStatus {
                entered.complete(Unit)
                try { awaitCancellation() } finally { withContext(NonCancellable) { draining.complete(Unit);finish.await();assertEquals(1,f.store.resourceImports().size) } }
            }
        }
        val activity=AccountResourceActivity(context,f.store,f.control,imports=control)
        var running: Job?=null;var closing: Job?=null
        try {
            val request=ResourceImportRequest(id(),ResourceImportSource.Message(RoomId(id()),MessageId(id()),id()),ResourceUsage.UserAvatar,id())
            f.store.prepareResourceImport(id(),request,System.currentTimeMillis());running=launch { activity.runForeground() }
            withTimeout(5000) { entered.await() };closing=launch { activity.close();f.store.close() };withTimeout(5000) { draining.await() }
            assertFalse(closing.isCompleted);assertNotNull(f.store.resourceImports().single().execution.owner)
            finish.complete(Unit);withTimeout(5000) { closing.join();running.join() };assertTrue(runCatching { f.store.resourceImports() }.isFailure)
        } finally { finish.complete(Unit);closing?.join();running?.cancelAndJoin();activity.close();f.store.close();f.source.delete() }
    }

    @Test fun foregroundAndBackgroundShareOneTransferAndForegroundExitDoesNotInterruptIt()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var transfers=0;var drained=false
        val activity=AccountResourceActivity(context,f.store,f.control) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                files.withOriginal(upload=work.id) {transfers++;entered.complete(Unit);try {finish.await()} finally {drained=true}}
            }
        }}
        try {
            f.prepare(activity);val foreground=launch {activity.runForeground()};withTimeout(5000) {entered.await()}
            val background=async(start=CoroutineStart.UNDISPATCHED) {activity.runBackground(5000)}
            foreground.cancelAndJoin();assertFalse(drained);assertFalse(background.isCompleted);assertEquals(1,transfers)
            finish.complete(Unit);assertEquals(ResourceBackgroundRunResult.Completed,withTimeout(5000) {background.await()})
            assertTrue(drained);assertEquals(ResourceUploadStage.Ready,f.store.resourceUploads().single().stage)
            assertNull(f.store.resourceUploads().single().execution.owner)
        } finally {finish.complete(Unit);activity.close();f.store.close();f.source.delete()}
    }
    @Test fun stoppingBackgroundKeepsForegroundTransferAndRejectsDuplicateBackground()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();var drained=false
        val activity=AccountResourceActivity(context,f.store,f.control) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                files.withOriginal(upload=work.id) {entered.complete(Unit);try {awaitCancellation()} finally {drained=true}}
            }
        }}
        try {
            f.prepare(activity);val foreground=launch {activity.runForeground()};withTimeout(5000) {entered.await()}
            val background=launch(start=CoroutineStart.UNDISPATCHED) {activity.runBackground()}
            assertTrue(runCatching {activity.runBackground()}.exceptionOrNull() is IllegalStateException)
            background.cancelAndJoin();assertFalse(drained);assertFalse(foreground.isCompleted)
            foreground.cancelAndJoin();assertTrue(drained)
            assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().single().execution.next)
        } finally {activity.close();f.store.close();f.source.delete()}
    }
    @Test fun backgroundBudgetWaitsForPhysicalDrainAndLeavesRecoverableJournal()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val draining=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val activity=AccountResourceActivity(context,f.store,f.control) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                files.withOriginal(upload=work.id) {entered.complete(Unit);try {awaitCancellation()} finally {withContext(NonCancellable) {draining.complete(Unit);finish.await();assertTrue(it.exists())}}}
            }
        }}
        try {
            f.prepare(activity);val background=async {activity.runBackground(1000)};withTimeout(5000) {entered.await();draining.await()}
            assertFalse(background.isCompleted);assertNotNull(f.store.resourceUploads().single().execution.owner)
            finish.complete(Unit);assertEquals(ResourceBackgroundRunResult.BudgetExpired,withTimeout(5000) {background.await()})
            assertNull(f.store.resourceUploads().single().execution.owner);assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().single().execution.next)
            assertFalse(f.store.resourceUploads().single().terminal)
        } finally {finish.complete(Unit);activity.close();f.store.close();f.source.delete()}
    }
    @Test fun accountCloseCancelsBothLeasesBeforeDatabaseCloseAndIdleBackgroundCompletes()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val draining=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val activity=AccountResourceActivity(context,f.store,f.control) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                files.withOriginal(upload=work.id) {entered.complete(Unit);try {awaitCancellation()} finally {withContext(NonCancellable) {draining.complete(Unit);finish.await()}}}
            }
        }}
        try {
            assertEquals(ResourceBackgroundRunResult.Completed,activity.runBackground())
            f.prepare(activity);val foreground=launch {activity.runForeground()};withTimeout(5000) {entered.await()}
            val background=launch(start=CoroutineStart.UNDISPATCHED) {activity.runBackground()}
            val closing=launch {activity.close();f.store.close()};withTimeout(5000) {draining.await()}
            assertFalse(closing.isCompleted);assertNotNull(f.store.resourceUploads().single().execution.owner)
            finish.complete(Unit);withTimeout(5000) {closing.join();foreground.join();background.join()}
            assertTrue(background.isCancelled);assertTrue(foreground.isCancelled)
        } finally {finish.complete(Unit);activity.close();f.store.close();f.source.delete()}
    }

}
