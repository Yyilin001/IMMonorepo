package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class ResourceDownloadCacheStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun target(bytes: String="abcdefgh"): MediaDownloadTarget {
        val checksum=MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") { "%02x".format(it) }
        val api=object: AuthenticatedTransport {
            override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse=error("no replay")
            override suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long)=EdgeResponse(200,buildJsonObject { put("plan",buildJsonObject {
                put("version",1);put("mode","http_get");put("url","https://provider.invalid/?signature=private");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",bytes.toByteArray().size);put("checksum",buildJsonObject { put("algorithm","sha256");put("value",checksum) })
            }) })
        }
        return MediaDownloadTargetClient(api).resolve(id(),null,null)
    }
    private suspend fun demand(files: ManagedResourceFiles,count: Int)=withTimeout(5000) { while(files.downloadDemandCount()!=count) delay(10) }
    private fun automatic(target:MediaDownloadTarget)=AutomaticResourceDownload(ResourceDescriptor(
        ResourceKey(ResourceHome.Account(actor),id()),1,"automatic.txt","text/plain",target.plan.expectedBytes,
        requireNotNull(target.plan.checksum),ResourceState.Ready,100,100))
    @Test fun manualConsumerPromotesOneQueuedAutomaticWriterAndCachedBytesNeedNoNetworkPermit()=runBlocking<Unit> {
        val store=store();val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=2,downloadTransferLimit=2,interactiveByteReserve=1))
        val occupied=scheduler.acquire(NetworkWorkContext("mediaProvider",NetworkWorkPriority.Background,NetworkWorkKind.Download))
        val release=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();val writes=AtomicInteger()
        val files=ManagedResourceFiles(context,store,scheduler=scheduler,download={_,file->
            assertNotNull(currentCoroutineContext()[AutomaticResourceDownload])
            val scope=requireNotNull(currentCoroutineContext()[NetworkWorkScope]);assertSame(scheduler,scope.scheduler)
            assertEquals(NetworkWorkPriority.Background,scope.work.priority)
            scheduler.withPermit(scope.work) {permit->
                assertEquals(NetworkWorkPriority.Interactive,permit.context.priority)
                writes.incrementAndGet();entered.complete(Unit);release.await();file.writeText("abcdefgh")
            }
        })
        try {coroutineScope {
            val target=target()
            val background=async(automatic(target)) {files.withDownloaded(target,false) {it.readText()}}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=1) delay(5)}
            assertEquals(0,writes.get())
            val manual=async {files.withDownloaded(target,false) {it.readText()}}
            withTimeout(5000) {entered.await()};demand(files,2)
            assertEquals(1,writes.get());assertEquals(2,scheduler.snapshot().activeDownloads)
            background.cancelAndJoin();assertFalse(manual.isCompleted)
            release.complete(Unit);assertEquals("abcdefgh",manual.await());assertEquals(1,writes.get())
            scheduler.release(occupied);scheduler.closeAndDrain()
            assertEquals("abcdefgh",files.withDownloaded(target,true) {it.readText()})
            assertEquals(0,scheduler.snapshot().active);assertEquals(1,writes.get())
        }} finally {release.complete(Unit);files.close();scheduler.release(occupied);scheduler.closeAndDrain();store.close()}
    }
    @Test fun queuedAutomaticFilesDoNotConsumeManualReservationInALocalSemaphore()=runBlocking<Unit> {
        val store=store();val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=2,downloadTransferLimit=2,interactiveByteReserve=1))
        val occupied=scheduler.acquire(NetworkWorkContext("mediaProvider",NetworkWorkPriority.Background,NetworkWorkKind.Download))
        val files=ManagedResourceFiles(context,store,scheduler=scheduler,download={target,file->
            val scope=requireNotNull(currentCoroutineContext()[NetworkWorkScope]);assertSame(scheduler,scope.scheduler)
            scheduler.withPermit(scope.work) {file.writeText(when(target.plan.expectedBytes) {8L->"abcdefgh";6L->"second";else->"manual!"})}
        })
        try {coroutineScope {
            val firstTarget=target();val secondTarget=target("second")
            val first=launch(automatic(firstTarget)) {files.withDownloaded(firstTarget,false) {error("cancelled")}}
            val second=launch(automatic(secondTarget)) {files.withDownloaded(secondTarget,false) {error("cancelled")}}
            withTimeout(5000) {while(scheduler.snapshot().waitingByteTransfers!=2) delay(5)}
            // A third writer must reach the leaf scheduler despite two queued automatic writers.
            assertEquals("manual!",withTimeout(5000) {files.withDownloaded(target("manual!"),false) {it.readText()}})
            first.cancelAndJoin();second.cancelAndJoin();assertEquals(0,scheduler.snapshot().waiting)
        }} finally {files.close();scheduler.release(occupied);scheduler.closeAndDrain();store.close()}
    }
    @Test fun verifiedCacheSurvivesReopenAndCorruptBytesNeverReachBorrower()=runBlocking<Unit> {
        var store=store();val transfers=AtomicInteger();var files=ManagedResourceFiles(context,store,download={ _,file->transfers.incrementAndGet();file.writeText("abcdefgh") })
        try {
            assertNull(files.withDownloaded(target(),true) { error("miss") });assertEquals(0,transfers.get())
            assertEquals("abcdefgh",files.withDownloaded(target(),false) { it.readText() });val id=store.resourceFiles().single().id
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store,download={ _,file->transfers.incrementAndGet();file.writeText("abcdefgh") })
            assertEquals("abcdefgh",files.withDownloaded(target(),true) { it.readText() });assertEquals(1,transfers.get());assertEquals(id,store.resourceFiles().single().id)
            val physical=File(context.noBackupFilesDir,"resources-${store.resourceScope}/files/$id");Os.chmod(physical.path,384);physical.writeText("xxxxxxxx")
            assertNull(files.withDownloaded(target(),true) { error("corrupt cache") })
            assertEquals("abcdefgh",files.withDownloaded(target(),false) { it.readText() });assertEquals(2,transfers.get())
            files.cleanup();assertEquals(1,store.resourceFiles().size);assertEquals(ResourceFileKind.Cache,store.resourceFiles().single().kind)
        } finally { files.close();store.close() }
    }
    @Test fun sharedBytesKeepRemainingWaiterAliveWhenOneCallerCancels()=runBlocking<Unit> {
        val store=store();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();val transfers=AtomicInteger()
        val files=ManagedResourceFiles(context,store,download={ _,file->transfers.incrementAndGet();entered.complete(Unit);release.await();file.writeText("abcdefgh") })
        try { coroutineScope {
            val first=launch { files.withDownloaded(target(),false) { error("cancelled borrower") } };entered.await()
            val second=async { files.withDownloaded(target(),false) { it.readText() } };demand(files,2)
            withTimeout(5000) { first.cancelAndJoin() };assertEquals(1,transfers.get());assertFalse(second.isCompleted)
            release.complete(Unit);assertEquals("abcdefgh",second.await());assertEquals(1,store.resourceFiles().size)
        } } finally { release.complete(Unit);files.close();store.close() }
    }
    @Test fun finalCancellationAndCloseDrainPhysicalWriterBeforeNextOwnerRecovers()=runBlocking<Unit> {
        val store=store();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        var files=ManagedResourceFiles(context,store,download={ _,file->entered.complete(Unit);withContext(NonCancellable) { release.await();file.writeText("abcdefgh") } })
        try {
            val reading=launch { files.withDownloaded(target(),false) { error("closed reader") } };entered.await()
            val closing=launch { files.close() };delay(50);assertFalse(closing.isCompleted);assertFalse(reading.isCompleted)
            release.complete(Unit);withTimeout(5000) { reading.join();closing.join() }
            files=ManagedResourceFiles(context,store,download={ _,_->error("verified staged bytes should recover") })
            assertEquals("abcdefgh",files.withDownloaded(target(),true) { it.readText() })
        } finally { release.complete(Unit);files.close();store.close() }
    }
    @Test fun newDemandWaitsForCancelledWriterToDrainBeforeRecoveringItsBytes()=runBlocking<Unit> {
        val store=store();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();val transfers=AtomicInteger()
        val files=ManagedResourceFiles(context,store,download={ _,file->transfers.incrementAndGet();entered.complete(Unit);withContext(NonCancellable) { release.await();file.writeText("abcdefgh") } })
        try { coroutineScope {
            val first=launch { files.withDownloaded(target(),false) { error("cancelled first demand") } };entered.await();first.cancel();demand(files,0)
            val second=async { files.withDownloaded(target(),false) { it.readText() } };delay(50)
            assertFalse(second.isCompleted);assertEquals(1,transfers.get())
            release.complete(Unit);withTimeout(5000) { first.join();assertEquals("abcdefgh",second.await()) };assertEquals(1,transfers.get())
        } } finally { release.complete(Unit);files.close();store.close() }
    }
    @Test fun evictionProtectsLiveBorrowsAndOriginalPromotionTransfersQuota()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={ _,file->file.writeText("abcdefgh") })
        try {
            files.withDownloaded(target(),false) { borrowed ->
                files.clearDownloadCache();assertTrue(borrowed.exists())
                val asset=files.importFile(borrowed,"copy.txt","text/plain",ResourceUsage.UserAvatar,1024)
                assertEquals(1,store.resourceFiles().size);assertEquals(ResourceFileKind.Original,store.resourceFiles().single().kind)
                files.clearDownloadCache();files.withOriginal(selection=asset.id) { assertEquals("abcdefgh",it.readText()) }
                files.discardSelection(asset.id);files.cleanup();assertTrue(borrowed.exists())
            }
            files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close() }
    }
    @Test fun cacheQuotaEvictsIdleFilesButRefusesToEvictAnActiveConsumer()=runBlocking<Unit> {
        val store=store();val transfers=AtomicInteger()
        val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumCacheBytes=65536,maximumCacheEntries=1),download={ target,file->transfers.incrementAndGet();file.writeText(if(target.plan.expectedBytes==8L) "abcdefgh" else "second") })
        try {
            assertTrue(runCatching { files.withDownloaded(target("x".repeat(65537)),false) { error("over budget") } }.isFailure);assertEquals(0,transfers.get())
            files.withDownloaded(target(),false) { borrowed ->
                assertTrue(runCatching { files.withDownloaded(target("second"),false) { error("no room") } }.isFailure)
                assertTrue(borrowed.exists());assertEquals(1,transfers.get())
            }
            assertEquals("second",files.withDownloaded(target("second"),false) { it.readText() });assertEquals(2,transfers.get());assertEquals(1,store.resourceFiles().size)
            assertNull(files.withDownloaded(target(),true) { error("evicted") })
        } finally { files.close();store.close() }
    }
    @Test fun stagedAndRenamedPublicationsRecoverAfterJournalInterruption()=runBlocking<Unit> {
        for(point in listOf(ManagedResourceFiles.PublicationCheckpoint.Copied,ManagedResourceFiles.PublicationCheckpoint.Renamed,ManagedResourceFiles.PublicationCheckpoint.Published)) {
            val store=SqliteClientStore(context,actor,DeviceId(id()))
            var files=ManagedResourceFiles(context,store,checkpoint={ if(it==point) throw java.io.IOException("simulated interruption") },download={ _,file->file.writeText("abcdefgh") })
            try {
                assertTrue(runCatching { files.withDownloaded(target(),false) { error("interrupted") } }.isFailure);val id=store.resourceFiles().single().id;files.close()
                files=ManagedResourceFiles(context,store,download={ _,_->error("recovery must not download") })
                assertEquals("abcdefgh",files.withDownloaded(target(),true) { it.readText() });assertEquals(id,store.resourceFiles().single().id)
                assertEquals(ResourceFileState.Published,store.resourceFiles().single().state)
            } finally { files.close();store.close() }
        }
    }
    @Test fun reducedQuotaCanRecoverAndThenClearAnAlreadyWrittenCheckpoint()=runBlocking<Unit> {
        val store=store();var files=ManagedResourceFiles(context,store,checkpoint={ if(it==ManagedResourceFiles.PublicationCheckpoint.Copied) throw java.io.IOException("simulated interruption") },download={ _,file->file.writeText("abcdefgh") })
        try {
            assertTrue(runCatching { files.withDownloaded(target(),false) { error("interrupted") } }.isFailure);files.close()
            store.setResourceStoragePolicy(ResourceOriginalPolicy(maximumCacheBytes=1))
            files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumCacheBytes=1),download={ _,_->error("no new admission") })
            assertEquals("abcdefgh",files.withDownloaded(target(),true) { it.readText() })
            assertTrue(store.resourceFiles().single().chargedBytes>1)
            files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close() }
    }
    @Test fun legacyFileRowsMigrateWithoutLosingOriginalSelectionsOrIdentity()=runBlocking<Unit> {
        var store=store();var files=ManagedResourceFiles(context,store)
        val source=File.createTempFile("legacy-original",".txt",context.filesDir).apply { writeText("abcdefgh") }
        try {
            val asset=files.importFile(source,"old.txt","text/plain",ResourceUsage.UserAvatar,1024);val fileId=asset.file;val scope=store.resourceScope
            files.close();store.close()
            SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$scope.db").path,null,SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("ALTER TABLE resource_files RENAME TO current_files")
                db.execSQL("CREATE TABLE resource_files(id TEXT PRIMARY KEY,bytes INTEGER NOT NULL CHECK(bytes>0),checksum TEXT NOT NULL,state TEXT NOT NULL,allocated INTEGER NOT NULL)")
                db.execSQL("INSERT INTO resource_files SELECT id,bytes,checksum,state,allocated FROM current_files");db.execSQL("DROP TABLE current_files")
            }
            store=store();files=ManagedResourceFiles(context,store)
            assertEquals(fileId,store.resourceFiles().single().id);assertEquals(ResourceFileKind.Original,store.resourceFiles().single().kind)
            files.withOriginal(selection=asset.id) { assertEquals("abcdefgh",it.readText()) }
            assertEquals("abcdefgh",files.withDownloaded(target(),true) { it.readText() })
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun emptyResourcesAreCachedAndAccountDeviceScopesCannotSharePhysicalBytes()=runBlocking<Unit> {
        val first=store();val second=SqliteClientStore(context,actor,DeviceId(id()));val count=AtomicInteger()
        val a=ManagedResourceFiles(context,first,download={ _,file->count.incrementAndGet();file.writeText("") })
        val b=ManagedResourceFiles(context,second,download={ _,file->count.incrementAndGet();file.writeText("") })
        try {
            assertEquals(0L,a.withDownloaded(target(""),false) { it.length() });assertNull(b.withDownloaded(target(""),true) { error("wrong scope") })
            assertEquals(0L,b.withDownloaded(target(""),false) { it.length() });assertEquals(2,count.get())
            a.clearDownloadCache();assertTrue(first.resourceFiles().isEmpty());assertEquals(1,second.resourceFiles().size)
        } finally { a.close();b.close();first.close();second.close() }
    }
}
