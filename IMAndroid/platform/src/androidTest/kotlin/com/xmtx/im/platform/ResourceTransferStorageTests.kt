package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ResourceTransferStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val now=System.currentTimeMillis()+10000
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        fun sql(body:(SQLiteDatabase)->Unit) {SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-${store.resourceScope}.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)}
        fun request()=ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),ResourceUsage.Attachment(room),id())
        suspend fun imported(job:String=id())=store.prepareResourceImport(job,request(),now)
        suspend fun upload(job:String=id()):ResourceUploadWork {
            val file=File.createTempFile("transfer-",".txt",context.cacheDir)
            try {file.writeText("transfer");val asset=files.importFile(file,"传输.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return store.prepareResourceUpload(job,asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
            } finally {file.delete()}
        }
        suspend fun download():ResourceDownloadWork {
            val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"下载.txt","text/plain",8,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
            store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100,0,descriptor.key.media),1000,descriptor)),100,null))
            return store.enqueueResourceDownload(descriptor.key,store.resourceSources(descriptor.key).sources.single(),now)
        }
        suspend fun row(key:ResourceTransferId)=store.resourceTransfers(ResourceTransferQuery(limit=100),now).entries.first {it.id==key}
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun close() {files.close();store.close()}
    }
    @Test fun typedKeysetPagesKeepAllThreeJournalsWithTheSameIdAndTimestampAcrossReopen()=runBlocking {
        val f=Fixture();try {
            val same=id();f.upload(same);f.imported(same);val download=f.download()
            f.sql {it.execSQL("UPDATE resource_uploads SET created=?",arrayOf(f.now));it.execSQL("UPDATE resource_downloads SET id=?",arrayOf(same))}
            val expected=listOf(ResourceTransferKind.Upload,ResourceTransferKind.ServerImport,ResourceTransferKind.Download).map {ResourceTransferId(it,same)}
            var cursor:ResourceTransferCursor?=null;val actual=mutableListOf<ResourceTransferId>()
            do {val page=f.store.resourceTransfers(ResourceTransferQuery(before=cursor,limit=1),f.now);actual+=page.entries.map {it.id};cursor=page.next} while(cursor!=null)
            assertEquals(expected,actual);assertNotEquals(download.id,same)
            val first=f.store.resourceTransfers(ResourceTransferQuery(limit=1),f.now)
            f.store.controlResourceTransfer(expected.first(),ResourceTransferAction.Pause,f.now);f.reopen()
            assertEquals(expected.drop(1),f.store.resourceTransfers(ResourceTransferQuery(before=first.next),f.now).entries.map {it.id})
            assertEquals(expected.first(),f.store.resourceTransfers(ResourceTransferQuery(ResourceTransferGroup.Attention),f.now).entries.single().id)
        } finally {f.close()}
    }
    @Test fun groupFilteringTraversesMoreThanOneHundredCanonicalRowsWithoutLosingOldAttentionWork()=runBlocking {
        val f=Fixture();try {
            val oldest=f.imported();f.store.controlResourceImport(oldest.id,true)
            f.sql {db->repeat(130) {index->val request=f.request();val status=ResourceImportStatus(request.locator(f.actor),request.targetMedia,ResourceImportState.Ready,f.now+60000)
                db.execSQL("INSERT INTO resource_imports(id,operation,media,request,status,created) VALUES(?,?,?,?,?,?)",arrayOf(id(),request.operation,request.targetMedia,request.payload().toString(),status.payload().toString(),f.now+index+1))}}
            assertEquals(oldest.id,f.store.resourceTransfers(ResourceTransferQuery(ResourceTransferGroup.Attention,limit=1),f.now).entries.single().id.value)
            val finished=f.store.resourceTransfers(ResourceTransferQuery(ResourceTransferGroup.Finished,limit=100),f.now);assertEquals(100,finished.entries.size);assertNotNull(finished.next)
            val rest=f.store.resourceTransfers(ResourceTransferQuery(ResourceTransferGroup.Finished,finished.next,100),f.now);assertEquals(30,rest.entries.size);assertNull(rest.next)
            assertEquals(130,(finished.entries+rest.entries).map {it.id}.distinct().size)
        } finally {f.close()}
    }
    @Test fun pauseWaitsForOwnerAndResumeResetsRoundWithoutBypassingServerRetryFloor()=runBlocking {
        val f=Fixture();try {
            val upload=f.upload();val key=ResourceTransferId(ResourceTransferKind.Upload,upload.id)
            val claim=f.store.claimResourceUpload(upload.id,id(),f.now)!!
            f.store.controlResourceTransfer(key,ResourceTransferAction.Pause,f.now)
            assertEquals(ResourceTransferPhase.Pausing,f.row(key).phase)
            assertTrue(runCatching {f.store.controlResourceTransfer(key,ResourceTransferAction.Resume,f.now)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            f.store.failResourceUpload(claim,ResourceUploadError.Transport,null,f.now+60000)
            val paused=f.row(key);assertEquals(ResourceTransferPhase.Paused,paused.phase)
            f.store.controlResourceTransfer(key,ResourceTransferAction.Resume,f.now);val resumed=f.store.resourceUploads().single()
            assertEquals(upload.request,resumed.request);assertEquals(0,resumed.execution.attempts);assertNull(resumed.execution.deadline);assertFalse(resumed.execution.attention)
            assertEquals(f.now+60000,resumed.execution.retryAt);assertNull(f.store.claimResourceUpload(upload.id,id(),f.now+1))
            assertTrue(runCatching {f.store.controlResourceTransfer(key,ResourceTransferAction.Resume,f.now)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            f.reopen();assertEquals(resumed,f.store.resourceUploads().single())
        } finally {f.close()}
    }
    @Test fun batchRetryDeduplicatesRechecksCapabilitiesAndNeverResumesPausedOrCancellationWork()=runBlocking {
        val f=Fixture();try {
            val retry=f.imported();val paused=f.imported();val cancel=f.imported()
            val retryKey=ResourceTransferId(ResourceTransferKind.ServerImport,retry.id);val pauseKey=ResourceTransferId(ResourceTransferKind.ServerImport,paused.id);val cancelKey=ResourceTransferId(ResourceTransferKind.ServerImport,cancel.id)
            f.store.failResourceImport(f.store.claimResourceImport(retry.id,id(),f.now)!!,ResourceImportIssue.Transport,null,f.now+60000)
            f.store.controlResourceTransfer(pauseKey,ResourceTransferAction.Pause,f.now)
            f.store.cancelUnboundResource(f.store.planUnboundResourceCancellation(cancelKey))
            f.store.failResourceImport(f.store.claimResourceImport(cancel.id,id(),f.now)!!,ResourceImportIssue.Transport,null,0)
            val result=f.store.retryResourceTransfers(persistentListOf(retryKey,pauseKey,cancelKey,retryKey),ResourceTransferAction.Retry,f.now)
            assertEquals(listOf(retryKey,pauseKey,cancelKey),result.items.map {it.id});assertEquals(1,result.requestedCount);assertEquals(2,result.skippedCount)
            assertEquals(ResourceTransferPhase.Paused,f.row(pauseKey).phase)
            assertEquals(persistentSetOf(ResourceTransferAction.RetryCancellation),f.row(cancelKey).actions)
            assertEquals(1,f.store.retryResourceTransfers(persistentListOf(cancelKey),ResourceTransferAction.RetryCancellation,f.now).requestedCount)
            val jobs=f.store.resourceImports();assertTrue(jobs.first {it.id==cancel.id}.cancellationRequested);assertEquals(retry.request,jobs.first {it.id==retry.id}.request)
            assertEquals(f.now+60000,jobs.first {it.id==retry.id}.execution.retryAt)
        } finally {f.close()}
    }
    @Test fun businessBindingBetweenReadAndCancellationRejectsStaleUnboundAction()=runBlocking {
        val f=Fixture();try {
            val work=f.imported();val key=ResourceTransferId(ResourceTransferKind.ServerImport,work.id)
            assertTrue(ResourceTransferAction.CancelUnbound in f.row(key).actions)
            val service=SendIntentService(f.actor,f.store) {f.now}
            service.enqueue(service.prepare(f.room,"关联业务",persistentListOf(),serverImports=persistentListOf(SendImportedAttachment(work.id,work.request))))
            assertTrue(f.row(key).hasBusinessOwners);assertFalse(ResourceTransferAction.CancelUnbound in f.row(key).actions)
            assertTrue(runCatching {f.store.controlResourceTransfer(key,ResourceTransferAction.CancelUnbound,f.now)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertFalse(f.store.resourceImports().single().cancellationRequested)
            f.reopen();assertTrue(f.row(key).hasBusinessOwners)
        } finally {f.close()}
    }
    @Test fun revokedDownloadsRemainCancellableAndCannotBeResumed()=runBlocking {
        val f=Fixture();try {
            val work=f.download();val key=ResourceTransferId(ResourceTransferKind.Download,work.id)
            f.store.controlResourceTransfer(key,ResourceTransferAction.Pause,f.now);f.store.unavailable(f.room)
            val row=f.row(key);assertNull(row.displayName);assertNull(row.resource);assertEquals(persistentSetOf(ResourceTransferAction.Cancel),row.actions)
            assertTrue(runCatching {f.store.controlResourceTransfer(key,ResourceTransferAction.Resume,f.now)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            f.store.controlResourceTransfer(key,ResourceTransferAction.Cancel,f.now);assertEquals(ResourceTransferGroup.Finished,f.row(key).group)
        } finally {f.close()}
    }
    @Test fun cancelledBatchKeepsFirstCommittedRetryAndLeavesRemainingJobsUntouched()=runBlocking {
        val f=Fixture();try {
            val jobs=(1..3).map {f.imported()};for(job in jobs) f.store.failResourceImport(f.store.claimResourceImport(job.id,id(),f.now)!!,ResourceImportIssue.Transport,null,0)
            val keys=jobs.map {ResourceTransferId(ResourceTransferKind.ServerImport,it.id)}.toPersistentList()
            lateinit var command:Job
            val observer=launch(Dispatchers.Unconfined) {f.store.resourceTransferChanges.drop(1).take(1).collect {command.cancel()}}
            command=launch(start=CoroutineStart.LAZY) {f.store.retryResourceTransfers(keys,ResourceTransferAction.Retry,f.now)}
            command.start();command.join();observer.join()
            assertFalse(f.store.resourceImports().first {it.id==jobs.first().id}.execution.attention)
            assertTrue(f.store.resourceImports().filter {it.id!=jobs.first().id}.all {it.execution.attention})
            assertTrue(runCatching {f.store.retryResourceTransfers(persistentListOf(),ResourceTransferAction.Retry,f.now)}.isFailure)
        } finally {f.close()}
    }
    @Test fun legacyUploadCreationTimestampIsBackfilledExactlyOnce() {
        SQLiteDatabase.create(null).use {db->
            db.execSQL("CREATE TABLE resource_assets(id TEXT PRIMARY KEY,planned_file TEXT,file_id TEXT,metadata TEXT,availability TEXT,selection INTEGER,created INTEGER)")
            db.execSQL("CREATE TABLE resource_uploads(id TEXT PRIMARY KEY,asset TEXT,operation TEXT,media TEXT,request TEXT,session TEXT,stage TEXT,cancelled INTEGER DEFAULT 0,released INTEGER DEFAULT 0)")
            val asset=id();val job=id();db.execSQL("INSERT INTO resource_assets VALUES(?,?,NULL,'{}','Local',1,123)",arrayOf(asset,id()))
            db.execSQL("INSERT INTO resource_uploads(id,asset,operation,media,request,stage) VALUES(?,?,?,?,'{}','Prepared')",arrayOf(job,asset,id(),id()))
            SqliteResourceFiles(db,UserId(id()))
            db.execSQL("UPDATE resource_assets SET created=999")
            SqliteResourceFiles(db,UserId(id()))
            db.rawQuery("SELECT created FROM resource_uploads WHERE id=?",arrayOf(job)).use {assertTrue(it.moveToFirst());assertEquals(123L,it.getLong(0))}
        }
    }
}
