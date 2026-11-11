package com.xmtx.im.platform

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.security.MessageDigest

class ResourceSelectionCleanupTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun hash(text:String)=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") {"%02x".format(it)})
    private fun descriptor(text:String="abcdefgh")=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"资源.txt","text/plain",text.length.toLong(),hash(text),ResourceState.Ready)
    private suspend fun catalog(store:SqliteClientStore,vararg values:ResourceDescriptor) {
        val scan=store.beginResourceDirectoryScan(room)
        store.applyResourceDirectoryPage(scan,RoomResourcePage(values.mapIndexed {i,value->RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-i,0,value.key.media),1,value)}.toPersistentList(),100,null))
    }
    private suspend fun target(value:ResourceDescriptor,text:String="abcdefgh",preview:ResourceVariantDescriptor?=null):MediaDownloadTarget {
        val transport=object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("not used")
            override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {
                put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url","https://provider.invalid/?signature=private");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                    put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60_000);put("expectedByteCount",text.length);put("checksum",hash(text).payload())
                });preview?.let {put("preview",it.payload())}
            })
        }
        return MediaDownloadTargetClient(transport).resolve(value.key.media,MediaMessageLocation(room,MessageId(id())),if(preview==null) null else MediaImagePreviewSize.Thumbnail)
    }
    @Test fun absentUnavailableAndDuplicateSelectionsNeverExpandToAllFiles()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("unrelated")})
        val missing=descriptor();val unrelated=descriptor("unrelated");val hidden=ResourceKey(ResourceHome.Room(RoomId(id())),id())
        try {
            catalog(store,missing);files.withDownloaded(target(unrelated,"unrelated")) {}
            assertTrue(runCatching {files.planSelectedCacheCleanup(persistentListOf())}.isFailure)
            assertTrue(runCatching {files.planSelectedCacheCleanup(List(101) {missing.key}.toPersistentList())}.isFailure)
            val preview=files.planSelectedCacheCleanup(persistentListOf(missing.key,missing.key,hidden))
            assertEquals(2,preview.resourceCount);assertEquals(1,preview.absentResourceCount);assertEquals(1,preview.unavailableResourceCount)
            assertEquals(0,preview.plan.fileCount);assertEquals(0,preview.plan.skippedCount)
            assertEquals(ResourceCleanupResult(0,0,0,0),files.commitCacheCleanup(preview.plan));assertEquals(1,store.resourceFiles().size)
        } finally {files.close();store.close()}
    }
    @Test fun selectedSharedBytesAreDeduplicatedAndUnselectedBytesSurvive()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.expectedBytes==8L) "abcdefgh" else "other")})
        val a=descriptor();val b=descriptor();val other=descriptor("other")
        try {
            catalog(store,a,b,other);files.withDownloaded(target(a)) {};files.withDownloaded(target(other,"other")) {}
            val preview=files.planSelectedCacheCleanup(persistentListOf(a.key,b.key,a.key))
            assertEquals(2,preview.resourceCount);assertEquals(1,preview.plan.fileCount);assertEquals(2,store.resourceFiles().size)
            assertEquals(ResourceCleanupResult(1,preview.plan.estimatedBytes,0,0),files.commitCacheCleanup(preview.plan))
            assertFalse(files.resourceVariants(a.key).single().availableLocally);assertFalse(files.resourceVariants(b.key).single().availableLocally)
            assertTrue(files.resourceVariants(other.key).single().availableLocally)
            assertTrue(runCatching {files.commitCacheCleanup(preview.plan)}.isFailure)
        } finally {files.close();store.close()}
    }
    @Test fun newBorrowAndSharedRetentionProtectAnAlreadyPreviewedFile()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("abcdefgh")});val a=descriptor();val b=descriptor()
        try {
            catalog(store,a,b);files.withDownloaded(target(a)) {}
            val beforeBorrow=files.planSelectedCacheCleanup(persistentListOf(a.key))
            files.withDownloaded(target(a)) {assertEquals(0,files.planSelectedCacheCleanup(persistentListOf(a.key)).plan.fileCount)}
            assertEquals(ResourceCleanupResult(0,0,1,0),files.commitCacheCleanup(beforeBorrow.plan))
            val beforeRetention=files.planSelectedCacheCleanup(persistentListOf(a.key))
            files.setResourceRetained(ResourceVariantKey(b.key),true)
            assertEquals(ResourceCleanupResult(0,0,1,0),files.commitCacheCleanup(beforeRetention.plan))
            val protected=files.planSelectedCacheCleanup(persistentListOf(a.key));assertEquals(0,protected.plan.fileCount);assertEquals(1,protected.plan.skippedCount)
            files.setResourceRetained(ResourceVariantKey(b.key),false)
            assertEquals(1,files.commitCacheCleanup(files.planSelectedCacheCleanup(persistentListOf(a.key)).plan).deletedCount)
        } finally {files.close();store.close()}
    }
    @Test fun pendingOriginalOwnershipIsProtectedEvenWhenSelectedByACacheResource()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("abcdefgh")});val a=descriptor()
        try {
            catalog(store,a);files.withDownloaded(target(a)) {files.importFile(it,"draft.txt","text/plain",ResourceUsage.Attachment(room),100)}
            val preview=files.planSelectedCacheCleanup(persistentListOf(a.key))
            assertEquals(0,preview.plan.fileCount);assertEquals(1,preview.plan.skippedCount)
            assertEquals(ResourceCleanupResult(0,0,1,0),files.commitCacheCleanup(preview.plan));assertEquals(ResourceFileKind.Original,store.resourceFiles().single().kind)
        } finally {files.close();store.close()}
    }
    @Test fun cleanupIncludesPublishedVersionsOutsideThe128ItemDetailPage()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("old")) "old" else "common")})
        val a=descriptor();val rendition=id()
        try {
            catalog(store,a);val read=store.selectMessageResource(a.key)
            // The oldest version is beyond the original-first, newest-derived
            // detail page, but must remain part of selected physical cleanup.
            for(version in 1..130) {
                val text=if(version==1) "old" else "common"
                val variant=ResourceVariantDescriptor(ResourceVariantKey(a.key,ResourceRendition.Derived(rendition,version.toLong())),hash(text),text.length.toLong())
                val target=target(a,text,variant);store.observeResourceVariant(read,target)
                if(version==1 || version==2) files.withDownloaded(target) {}
            }
            val page=files.resourceVariants(a.key);assertEquals(128,page.size);assertTrue(page.none {it.descriptor.checksum==hash("old")})
            val preview=files.planSelectedCacheCleanup(persistentListOf(a.key));assertEquals(2,preview.plan.fileCount)
            assertEquals(2,files.commitCacheCleanup(preview.plan).deletedCount);assertTrue(store.resourceFiles().isEmpty())
        } finally {files.close();store.close()}
    }
    @Test fun logicalSelectionDoesNotSweepUnpublishedPartialDownloads()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("abc");throw java.io.IOException("interrupted")});val a=descriptor()
        try {
            catalog(store,a);assertTrue(runCatching {files.withDownloaded(target(a)) {fail()}}.isFailure)
            val selected=files.planSelectedCacheCleanup(persistentListOf(a.key))
            assertEquals(1,selected.absentResourceCount);assertEquals(0,selected.plan.fileCount)
            files.commitCacheCleanup(selected.plan);assertEquals(1,store.resourceFiles().size)
            assertEquals(1,files.planCacheCleanup().fileCount)
        } finally {files.close();store.close()}
    }
}
