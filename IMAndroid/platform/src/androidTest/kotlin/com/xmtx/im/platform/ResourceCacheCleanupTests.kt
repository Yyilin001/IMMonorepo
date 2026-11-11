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

class ResourceCacheCleanupTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun hash(text:String)=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") {"%02x".format(it)})
    private fun descriptor(text:String)=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"private.txt","text/plain",text.length.toLong(),hash(text),ResourceState.Ready)
    private suspend fun target(text:String)=MediaDownloadTargetClient(object:AuthenticatedTransport {
        override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("not used")
        override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
            put("version",1);put("mode","http_get");put("url","https://provider.invalid/file");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
            put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",text.length);put("checksum",hash(text).payload())
        })})
    }).resolve(id(),MediaMessageLocation(room,MessageId(id())),null)
    private suspend fun retain(store:SqliteClientStore,files:ManagedResourceFiles,text:String) {
        val v=descriptor(text);store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(MessageId(id()),1,RoomResourcePosition(1,0,v.key.media),1,v)),1,null))
        files.setResourceRetained(ResourceVariantKey(v.key),true)
    }
    @Test fun previewIsReadOnlyDeduplicatedAndCommitOnlyDeletesPreviewedUnprotectedBytes()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("cache")) "cache" else if(t.plan.checksum==hash("retain")) "retain" else "new")})
        val source=File.createTempFile("cleanup-original",".txt",context.cacheDir).apply {writeText("original")}
        try {
            files.withDownloaded(target("cache")) {};files.withDownloaded(target("cache")) {}
            retain(store,files,"retain");files.withDownloaded(target("retain")) {}
            files.importFile(source,"original.txt","text/plain",ResourceUsage.Attachment(room),100)
            val before=files.storageSnapshot();val plan=files.planCacheCleanup()
            assertEquals(1,plan.fileCount);assertEquals(2,plan.skippedCount);assertEquals(before.cacheAllocatedBytes,plan.estimatedBytes)
            assertEquals(before,files.storageSnapshot());files.withDownloaded(target("new")) {}
            val result=files.commitCacheCleanup(plan);assertEquals(ResourceCleanupResult(1,plan.estimatedBytes,2,0),result)
            assertEquals(3,store.resourceFiles().size);assertEquals(before.originalAllocatedBytes,files.storageSnapshot().originalAllocatedBytes)
            assertEquals(before.retainedAllocatedBytes,files.storageSnapshot().retainedAllocatedBytes)
            assertTrue(runCatching {files.commitCacheCleanup(plan)}.isFailure)
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun newlyRetainedPromotedBorrowedAndRecentlyReadFilesAreSkipped()=runBlocking {
        val store=store();val values=listOf("retain","promote","borrow","recent")
        val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(values.first {hash(it)==t.plan.checksum})})
        val source=File.createTempFile("cleanup-promote",".txt",context.cacheDir).apply {writeText("promote")}
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var use:Job?=null
        try {
            for(value in values) files.withDownloaded(target(value)) {}
            val plan=files.planCacheCleanup();assertEquals(4,plan.fileCount)
            retain(store,files,"retain");files.importFile(source,"promote.txt","text/plain",ResourceUsage.Attachment(room),100)
            use=launch {files.withDownloaded(target("borrow")) {entered.complete(Unit);finish.await();assertEquals("borrow",it.readText())}}
            entered.await();files.withDownloaded(target("recent")) {}
            assertEquals(ResourceCleanupResult(0,0,4,0),files.commitCacheCleanup(plan));assertEquals(4,store.resourceFiles().size)
            finish.complete(Unit);use.join()
        } finally {finish.complete(Unit);use?.cancelAndJoin();files.close();store.close();source.delete()}
    }
    @Test fun idleResumeSidecarsAreCountedAndDeletedWhileActiveTransferIsProtected()=runBlocking {
        val store=store();val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var use:Job?=null
        val files=ManagedResourceFiles(context,store,download={t,f->
            if(t.plan.checksum==hash("idle")) {
                for(suffix in listOf(".range-part",".range-journal",".range-journal-new")) File(f.parentFile,f.name+suffix).writeText("checkpoint")
                throw java.io.IOException("interrupted")
            } else {f.writeText("active");entered.complete(Unit);finish.await()}
        })
        try {
            assertTrue(runCatching {files.withDownloaded(target("idle")) {fail()}}.isFailure)
            use=launch {files.withDownloaded(target("active")) {assertEquals("active",it.readText())}};entered.await()
            val plan=files.planCacheCleanup();assertEquals(1,plan.fileCount);assertEquals(1,plan.skippedCount);assertTrue(plan.estimatedBytes>0)
            assertEquals(ResourceCleanupResult(1,plan.estimatedBytes,1,0),files.commitCacheCleanup(plan))
            assertEquals(1,store.resourceFiles().size);finish.complete(Unit);use.join();assertTrue(files.storageSnapshot().cacheAllocatedBytes>0)
            assertEquals(0,files.storageSnapshot().transferAllocatedBytes)
        } finally {finish.complete(Unit);use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun resumingThenCancellingTheSamePhysicalDownloadInvalidatesItsOldPreview()=runBlocking {
        val store=store();val first=CompletableDeferred<Unit>();val second=CompletableDeferred<Unit>();var calls=0;var use:Job?=null
        val files=ManagedResourceFiles(context,store,download={_,f->
            File(f.parentFile,f.name+".range-part").writeText("checkpoint");calls++;if(calls==1) first.complete(Unit) else second.complete(Unit);awaitCancellation()
        })
        try {
            use=launch {files.withDownloaded(target("resume")) {fail()}};first.await();use.cancelAndJoin()
            val identity=store.resourceFiles().single().id;val plan=files.planCacheCleanup();assertEquals(1,plan.fileCount)
            use=launch {files.withDownloaded(target("resume")) {fail()}};second.await();use.cancelAndJoin()
            assertEquals(identity,store.resourceFiles().single().id)
            assertEquals(ResourceCleanupResult(0,0,1,0),files.commitCacheCleanup(plan));assertEquals(1,files.planCacheCleanup().fileCount)
        } finally {use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun expirationTamperingForeignOwnerAndRecreationCannotAuthorizeDeletion()=runBlocking {
        var store=store();var now=100L
        var files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")},cleanupClock={now})
        val other=SqliteClientStore(context,UserId(id()),DeviceId(id()));val otherFiles=ManagedResourceFiles(context,other,cleanupClock={now})
        try {
            files.withDownloaded(target("cache")) {}
            val altered=files.planCacheCleanup();assertTrue(runCatching {files.commitCacheCleanup(altered.copy(fileCount=2))}.isFailure)
            val expired=files.planCacheCleanup();now+=30_000;assertTrue(runCatching {files.commitCacheCleanup(expired)}.isFailure)
            val backwards=files.planCacheCleanup();now--;assertTrue(runCatching {files.commitCacheCleanup(backwards)}.isFailure);now++
            val plan=files.planCacheCleanup();assertTrue(runCatching {otherFiles.commitCacheCleanup(plan)}.isFailure)
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store,cleanupClock={now})
            assertTrue(runCatching {files.commitCacheCleanup(plan)}.isFailure);assertEquals(1,store.resourceFiles().size)
            val fresh=files.planCacheCleanup();assertEquals(1,files.commitCacheCleanup(fresh).deletedCount)
        } finally {files.close();store.close();otherFiles.close();other.close()}
    }
    @Test fun replacementAfterEvictionIsOutsideTheOldPreview()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
        try {
            files.withDownloaded(target("cache")) {};val old=store.resourceFiles().single().id;val plan=files.planCacheCleanup()
            files.clearDownloadCache();files.withDownloaded(target("cache")) {};assertNotEquals(old,store.resourceFiles().single().id)
            assertEquals(ResourceCleanupResult(0,0,1,0),files.commitCacheCleanup(plan));assertEquals(1,store.resourceFiles().size)
        } finally {files.close();store.close()}
    }
    @Test fun oneUnsafeSidecarReportsFailureWithoutBlockingOtherCandidatesAndCanBeRetried()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("cache")) "cache" else "other")})
        var unsafe:File?=null
        try {
            var first:File?=null;files.withDownloaded(target("cache")) {first=it};files.withDownloaded(target("other")) {}
            val plan=files.planCacheCleanup();val file=requireNotNull(first)
            unsafe=File(File(file.parentFile!!.parentFile,"partials"),file.name+".range-journal").apply {check(mkdir())}
            val result=files.commitCacheCleanup(plan);assertEquals(1,result.deletedCount);assertEquals(1,result.failedCount);assertEquals(0,result.skippedCount)
            assertEquals(1,store.resourceFiles().size);assertTrue(file.exists());check(unsafe.delete())
            val retry=files.planCacheCleanup();assertEquals(1,files.commitCacheCleanup(retry).deletedCount)
        } finally {unsafe?.delete();files.close();store.close()}
    }
    @Test fun retirementRechecksJournalProtectionAndUnfinishedDeletionRecoversAfterReopen()=runBlocking {
        var store=store();var files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
        try {
            files.withDownloaded(target("cache")) {};val before=store.resourceFiles().single();retain(store,files,"cache")
            assertFalse(store.beginResourceCacheCleanup(before));assertEquals(ResourceFileState.Published,store.resourceFiles().single().state)
            files.withDownloaded(target("cache")) {};files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            // A different unretained file enters the existing crash-recoverable Retiring state.
            files.close();files=ManagedResourceFiles(context,store,download={_,f->f.writeText("other")})
            files.withDownloaded(target("other")) {};val victim=store.resourceFiles().single {it.checksum==hash("other")}
            assertTrue(store.beginResourceCacheCleanup(victim));files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            files.storageSnapshot();assertEquals(1,store.resourceFiles().size);assertTrue(store.resourceFiles().single().retained)
        } finally {files.close();store.close()}
    }
}
