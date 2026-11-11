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

class ResourceStoragePolicyTests {
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
    @Test fun defaultsAndExplicitPolicySurviveReopenAndStayAccountScoped()=runBlocking {
        var store=store();val initial=ResourceOriginalPolicy(maximumCacheBytes=65536,maximumCacheEntries=7);var files=ManagedResourceFiles(context,store,initial)
        val other=SqliteClientStore(context,UserId(id()),DeviceId(id()));val otherFiles=ManagedResourceFiles(context,other)
        try {
            assertEquals(initial,files.storageSnapshot().policy);files.close();store.close();store=store();files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumCacheBytes=1))
            assertEquals(initial,files.storageSnapshot().policy)
            val custom=initial.copy(maximumOriginalBytes=999999,maximumTemporaryBytes=888888,minimumFreeBytes=777,maximumSelections=12,retainedWarningBytes=666666,maximumRetainedEntries=13)
            files.setStoragePolicy(custom);files.setCacheLimit(131072)
            assertEquals(custom.copy(maximumCacheBytes=131072),files.storageSnapshot().policy)
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            assertEquals(custom.copy(maximumCacheBytes=131072),files.storageSnapshot().policy);assertEquals(ResourceOriginalPolicy(),otherFiles.storageSnapshot().policy)
        } finally {files.close();store.close();otherFiles.close();other.close()}
    }
    @Test fun physicalUsageDeduplicatesBytesAndSeparatesRetainedOriginalAndCacheCharges()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("cache")) "cache" else "retain")})
        val source=File.createTempFile("storage-original",".txt",context.cacheDir).apply {writeText("original")}
        try {
            files.withDownloaded(target("cache")) {};files.withDownloaded(target("cache")) {}
            retain(store,files,"retain");files.withDownloaded(target("retain")) {}
            files.importFile(source,"original.txt","text/plain",ResourceUsage.Attachment(room),100)
            val s=files.storageSnapshot();assertEquals(3,store.resourceFiles().size);assertEquals(1,s.cacheEntries)
            assertTrue(s.cacheAllocatedBytes>=5);assertTrue(s.retainedAllocatedBytes>=6);assertTrue(s.originalAllocatedBytes>=8);assertEquals(0,s.transferAllocatedBytes)
            assertEquals(store.resourceFiles().sumOf {it.allocatedBytes},s.totalAllocatedBytes)
            assertEquals(store.resourceFiles().filter {it.kind==ResourceFileKind.Cache && !it.retained}.sumOf {it.chargedBytes},s.cacheChargedBytes)
            files.setCacheLimit(1);val after=files.storageSnapshot()
            assertEquals(0,after.cacheAllocatedBytes);assertEquals(s.retainedAllocatedBytes,after.retainedAllocatedBytes);assertEquals(s.originalAllocatedBytes,after.originalAllocatedBytes)
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun loweringQuotaDefersBorrowedCacheAndLaterCleanupUsesSavedLimit()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")});val borrowed=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();var use:Job?=null
        try {
            use=launch {files.withDownloaded(target("cache")) {file->borrowed.complete(Unit);gate.await();assertEquals("cache",file.readText())}}
            borrowed.await();val result=files.setCacheLimit(1);assertTrue(result.cleanupDeferred);assertTrue(result.snapshot.cacheOverLimit);assertEquals(1,store.resourceFiles().size)
            gate.complete(Unit);use.join();files.cleanup();assertEquals(0,files.storageSnapshot().cacheChargedBytes)
        } finally {gate.complete(Unit);use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun admittedDownloadCompletesAfterLimitReductionAndPartialDiskBytesAreNotDoubleCounted()=runBlocking {
        val store=store();val started=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val files=ManagedResourceFiles(context,store,download={_,file->file.writeText("cache");started.complete(Unit);finish.await()});var use:Deferred<String?>?=null
        try {
            use=async {files.withDownloaded(target("cache")) {it.readText()}};started.await()
            val before=files.storageSnapshot();assertTrue(before.transferAllocatedBytes>0);assertEquals(0,before.cacheAllocatedBytes);assertEquals(before.transferAllocatedBytes,before.totalAllocatedBytes);assertTrue(before.temporaryReservedBytes>=5)
            assertTrue(files.setCacheLimit(1).cleanupDeferred);finish.complete(Unit);assertEquals("cache",use.await())
            assertTrue(files.storageSnapshot().cacheOverLimit);assertTrue(runCatching {files.withDownloaded(target("another")) {fail()}}.isFailure)
            files.cleanup();assertEquals(0,files.storageSnapshot().totalAllocatedBytes)
        } finally {finish.complete(Unit);use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun cachedFilePromotedToOriginalIsCountedOnceAndNeverEvictedByCachePolicy()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")});val source=File.createTempFile("storage-promote",".txt",context.cacheDir).apply {writeText("cache")}
        try {
            files.withDownloaded(target("cache")) {};val before=files.storageSnapshot()
            files.importFile(source,"same.txt","text/plain",ResourceUsage.Attachment(room),100)
            val after=files.setCacheLimit(1).snapshot;assertEquals(before.totalAllocatedBytes,after.totalAllocatedBytes);assertEquals(0,after.cacheAllocatedBytes);assertEquals(before.totalAllocatedBytes,after.originalAllocatedBytes);assertEquals(1,store.resourceFiles().size)
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun persistedAdmissionSurvivesRestartWithAnIncompleteCheckpointAndLowerQuota()=runBlocking {
        var store=store();val initial=ResourceOriginalPolicy(maximumCacheBytes=65536);val started=CompletableDeferred<Unit>();var running:Job?=null
        var files=ManagedResourceFiles(context,store,initial,download={_,file->
            File(file.parentFile,file.name+".range-part").writeText("ca");started.complete(Unit);awaitCancellation()
        })
        try {
            running=launch {files.withDownloaded(target("cache")) {fail()}};started.await()
            val identity=store.resourceFiles().single().id;assertEquals(ResourceFileState.Publishing,store.resourceFiles().single().state)
            assertTrue(files.setCacheLimit(1).cleanupDeferred);running.cancelAndJoin()
            files.close();store.close();store=store()
            files=ManagedResourceFiles(context,store,download={_,file->file.writeText("cache")})
            assertEquals(1L,files.storageSnapshot().policy.maximumCacheBytes)
            assertEquals("cache",files.withDownloaded(target("cache")) {it.readText()});assertEquals(identity,store.resourceFiles().single().id)
            files.cleanup();assertEquals(0,files.storageSnapshot().totalAllocatedBytes)
        } finally {running?.cancelAndJoin();files.close();store.close()}
    }
}
