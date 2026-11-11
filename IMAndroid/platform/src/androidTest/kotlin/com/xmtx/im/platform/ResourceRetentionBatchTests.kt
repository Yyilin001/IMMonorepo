package com.xmtx.im.platform

import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.security.MessageDigest

class ResourceRetentionBatchTests {
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
    @Test fun batchDeduplicatesPreservesOutcomesAndPersistsWithoutStartingDownloads()=runBlocking<Unit> {
        var store=store();var files=ManagedResourceFiles(context,store,download={_,_->error("must not download")})
        val a=descriptor();val b=descriptor("second");val hidden=ResourceKey(ResourceHome.Room(RoomId(id())),id())
        try {
            catalog(store,a,b);files.setResourceRetained(ResourceVariantKey(a.key),true)
            val result=files.setResourcesRetained(persistentListOf(b.key,a.key,hidden,b.key),true)
            assertEquals(listOf(b.key,a.key,hidden),result.items.map {it.key})
            assertEquals(listOf(ResourceRetentionBatchOutcome.Changed,ResourceRetentionBatchOutcome.Unchanged,ResourceRetentionBatchOutcome.Unavailable),result.items.map {it.outcome})
            assertEquals(1,result.changedCount);assertEquals(2,result.skippedCount);assertTrue(result.failedKeys.isEmpty());assertTrue(store.resourceFiles().isEmpty())
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            assertTrue(files.resourceVariants(b.key).single().retained)
            assertEquals(2,files.setResourcesRetained(persistentListOf(a.key,b.key),false).changedCount)
            assertEquals(2,files.setResourcesRetained(persistentListOf(a.key,b.key),false).unchangedCount)
            assertTrue(store.resourceFiles().isEmpty())
        } finally {files.close();store.close()}
    }
    @Test fun capacityFailureRollsBackOnlyThatItemAndLaterSharedBytesCanStillBeRetained()=runBlocking<Unit> {
        val store=store();val a=descriptor();val b=descriptor("other");val shared=descriptor();val hidden=ResourceKey(ResourceHome.Room(RoomId(id())),id())
        val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumRetainedEntries=1),download={t,f->f.writeText(if(t.plan.expectedBytes==8L) "abcdefgh" else "other")})
        try {
            catalog(store,a,b,shared);files.withDownloaded(target(a)) {};files.withDownloaded(target(b,"other")) {};files.setResourceRetained(ResourceVariantKey(a.key),true)
            val result=files.setResourcesRetained(persistentListOf(b.key,shared.key,hidden,a.key),true)
            assertEquals(listOf(ResourceRetentionBatchOutcome.LimitReached,ResourceRetentionBatchOutcome.Changed,ResourceRetentionBatchOutcome.Unavailable,ResourceRetentionBatchOutcome.Unchanged),result.items.map {it.outcome})
            assertEquals(persistentListOf(b.key),result.failedKeys);assertEquals(1,result.limitReachedCount);assertEquals(2,store.resourceFiles().size)
            assertFalse(files.resourceVariants(b.key).single().retained);assertTrue(files.resourceVariants(shared.key).single().retained)
            files.setResourcesRetained(persistentListOf(a.key,shared.key),false)
            assertEquals(1,files.setResourcesRetained(result.failedKeys,true).changedCount)
            assertTrue(files.resourceVariants(b.key).single().retained);assertFalse(files.resourceVariants(a.key).single().retained)
        } finally {files.close();store.close()}
    }
    @Test fun unavailableReleaseDoesNotSilentlyDiscardRetentionIntent()=runBlocking<Unit> {
        val store=store();val a=descriptor();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("abcdefgh")})
        try {
            catalog(store,a);files.setResourcesRetained(persistentListOf(a.key),true);files.withDownloaded(target(a)) {};store.unavailable(room)
            val result=files.setResourcesRetained(persistentListOf(a.key),false)
            assertEquals(1,result.unavailableCount);assertEquals(0,result.changedCount);assertTrue(store.resourceFiles().single().retained)
            val plan=files.planUnavailableRetentionRelease();assertEquals(1,plan.count);files.releaseUnavailableRetention(plan)
            assertFalse(store.resourceFiles().single().retained);assertEquals(1,store.resourceFiles().size)
        } finally {files.close();store.close()}
    }
    @Test fun originalAndExplicitVersionRetentionDoNotDependOnThe128ItemDetailPage()=runBlocking<Unit> {
        val store=store();val a=descriptor();val files=ManagedResourceFiles(context,store);val rendition=id()
        try {
            catalog(store,a);val read=store.selectMessageResource(a.key)
            for(version in 1..130) {
                val v=ResourceVariantDescriptor(ResourceVariantKey(a.key,ResourceRendition.Derived(rendition,version.toLong())),hash("thumb"),5)
                store.observeResourceVariant(read,target(a,"thumb",v))
            }
            val page=files.resourceVariants(a.key);assertEquals(128,page.size);assertEquals(ResourceRendition.Original,page.first().descriptor.key.rendition)
            assertEquals(ResourceRendition.Original,store.resourceDetails(a.key)!!.variants.first().descriptor.key.rendition)
            assertEquals((130L downTo 4L).toList(),page.drop(1).map {(it.descriptor.key.rendition as ResourceRendition.Derived).version})
            assertEquals(1,files.setResourcesRetained(persistentListOf(a.key),true).changedCount)
            assertTrue(store.resourceVariant(ResourceVariantKey(a.key))!!.retained)
            files.setResourceRetained(ResourceVariantKey(a.key),false);files.setResourceRetained(ResourceVariantKey(a.key),true)
            val last=ResourceVariantKey(a.key,ResourceRendition.Derived(rendition,1));assertTrue(page.none {it.descriptor.key==last});files.setResourceRetained(last,true)
            files.setResourcesRetained(persistentListOf(a.key),false)
            assertFalse(store.resourceVariant(ResourceVariantKey(a.key))!!.retained);assertTrue(store.resourceVariant(last)!!.retained)
        } finally {files.close();store.close()}
    }
    @Test fun retainingCorruptBytesDoesNotMarkThemAvailable()=runBlocking<Unit> {
        val store=store();val a=descriptor();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("abcdefgh")})
        try {
            catalog(store,a);files.withDownloaded(target(a)) {Os.chmod(it.path,384);it.writeText("corrupt!")}
            val result=files.setResourcesRetained(persistentListOf(a.key),true);assertEquals(1,result.changedCount)
            val variant=files.resourceVariants(a.key).single();assertTrue(variant.retained);assertFalse(variant.availableLocally)
            files.withDownloaded(target(a)) {assertEquals("abcdefgh",it.readText())};assertTrue(files.resourceVariants(a.key).single().availableLocally)
        } finally {files.close();store.close()}
    }
    @Test fun cancellationAfterACommittedItemStopsTheRemainderWithoutRollingBackThatItem()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store);val values=listOf(descriptor(),descriptor("second"),descriptor("third"))
        var observer:Job?=null;var work:Job?=null
        try {
            catalog(store,*values.toTypedArray());values.forEach {files.resourceVariants(it.key)}
            val batch=launch(start=CoroutineStart.LAZY) {files.setResourcesRetained(values.map {it.key}.toPersistentList(),true);fail("must propagate cancellation")};work=batch
            // StateFlow emits after the writer commits. Unconfined observation
            // cancels synchronously at that boundary, without sleeps or hooks.
            observer=launch(Dispatchers.Unconfined,start=CoroutineStart.UNDISPATCHED) {store.resourceDirectoryChanges.drop(1).take(1).collect {batch.cancel()}}
            batch.start();withTimeout(5000) {batch.join();requireNotNull(observer).join()};assertTrue(batch.isCancelled)
            assertTrue(store.resourceVariant(ResourceVariantKey(values[0].key))!!.retained)
            assertTrue(values.drop(1).all {!store.resourceVariant(ResourceVariantKey(it.key))!!.retained})
        } finally {work?.cancelAndJoin();observer?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun invalidInputAndClosedOwnerFailTheWholeCallBeforeMutating()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store);val a=descriptor()
        try {
            catalog(store,a)
            assertTrue(runCatching {files.setResourcesRetained(persistentListOf(),true)}.isFailure)
            assertTrue(runCatching {files.setResourcesRetained(List(101) {a.key}.toPersistentList(),true)}.isFailure)
            files.close();assertTrue(runCatching {files.setResourcesRetained(persistentListOf(a.key),true)}.isFailure)
            assertFalse(store.resourceVariant(ResourceVariantKey(a.key))!!.retained)
        } finally {files.close();store.close()}
    }
}
