package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID

class UnavailableRetentionStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest("bytes".toByteArray()).joinToString("") {"%02x".format(it)})
    private fun descriptor(room:RoomId=this.room)=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"不可公开的文件名.txt","text/plain",5,checksum,ResourceState.Ready)
    private suspend fun catalog(store:SqliteClientStore,values:List<ResourceDescriptor>) {
        for(group in values.chunked(50)) {
            val room=(group.first().key.home as ResourceHome.Room).room
            store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(group.mapIndexed {i,v->RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-i,0,v.key.media),1,v)}.toPersistentList(),100,null))
        }
    }
    private suspend fun retain(files:ManagedResourceFiles,values:List<ResourceDescriptor>) {for(v in values) files.setResourceRetained(ResourceVariantKey(v.key),true)}
    private var membershipRevision=0L
    private suspend fun restore(store:SqliteClientStore,value:ResourceDescriptor) {
        store.acceptState((value.key.home as ResourceHome.Room).room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(++membershipRevision).build())
        catalog(store,listOf(value));assertNotNull(store.resourceDetails(value.key))
    }
    @Test fun previewIsBoundedHidesMetadataAndReleaseCanBeRepeatedWithoutDeletingBytes()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val values=(0..100).map {descriptor()}
        try {
            catalog(store,values);retain(files,values);assertEquals(0,files.planUnavailableRetentionRelease().count)
            store.unavailable(room);val plan=files.planUnavailableRetentionRelease()
            assertEquals(100,plan.count);assertTrue(plan.hasMore);assertFalse(plan.toString().contains(values.first().displayName));assertFalse(plan.toString().contains(values.first().key.media))
            assertEquals(ResourceUnavailableRetentionResult(100,0),files.releaseUnavailableRetention(plan))
            assertEquals(ResourceUnavailableRetentionResult(0,100),files.releaseUnavailableRetention(plan))
            val next=files.planUnavailableRetentionRelease();assertEquals(1,next.count);assertFalse(next.hasMore)
            files.releaseUnavailableRetention(next);assertEquals(0,files.planUnavailableRetentionRelease().count)
        } finally {files.close();store.close()}
    }
    @Test fun restoredVisibilityWinsAtCommitAndFuturePreviewCanReconsiderSkippedIntent()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val value=descriptor()
        try {
            catalog(store,listOf(value));retain(files,listOf(value));store.unavailable(room);val plan=files.planUnavailableRetentionRelease()
            restore(store,value);assertEquals(ResourceUnavailableRetentionResult(0,1),files.releaseUnavailableRetention(plan))
            assertTrue(files.resourceVariants(value.key).single().retained)
            store.unavailable(room);val next=files.planUnavailableRetentionRelease();assertEquals(1,next.count)
            assertEquals(1,files.releaseUnavailableRetention(next).releasedCount)
        } finally {files.close();store.close()}
    }
    @Test fun oldPlanCannotRemoveARecreatedIntentEvenAfterSuccessfulReplay()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val value=descriptor()
        try {
            catalog(store,listOf(value));retain(files,listOf(value));store.unavailable(room);val plan=files.planUnavailableRetentionRelease()
            restore(store,value);files.setResourceRetained(ResourceVariantKey(value.key),false);retain(files,listOf(value));store.unavailable(room)
            assertEquals(ResourceUnavailableRetentionResult(0,1),files.releaseUnavailableRetention(plan))
            val current=files.planUnavailableRetentionRelease();assertEquals(1,files.releaseUnavailableRetention(current).releasedCount)
            restore(store,value);retain(files,listOf(value));store.unavailable(room)
            assertEquals(ResourceUnavailableRetentionResult(0,1),files.releaseUnavailableRetention(current))
            assertEquals(1,files.planUnavailableRetentionRelease().count)
        } finally {files.close();store.close()}
    }
    @Test fun foreignTamperedExpiredAndClockRolledBackPlansCannotReleaseAnything()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store);val other=SqliteClientStore(context,UserId(id()),DeviceId(id()));val value=descriptor();val now=System.currentTimeMillis()
        try {
            catalog(store,listOf(value));retain(files,listOf(value));store.unavailable(room);val plan=store.planUnavailableRetentionRelease {now}
            assertTrue(runCatching {other.releaseUnavailableRetention(plan) {now}}.isFailure)
            assertTrue(runCatching {store.releaseUnavailableRetention(plan.copy(count=0)) {now}}.isFailure)
            assertTrue(runCatching {store.releaseUnavailableRetention(plan) {now-1}}.isFailure)
            assertTrue(runCatching {store.releaseUnavailableRetention(plan) {plan.expiresAt}}.isFailure)
            assertEquals(1,files.planUnavailableRetentionRelease().count)
        } finally {files.close();store.close();other.close()}
    }
    @Test fun accountReopenPreservesPreviewAndIntentComparison()=runBlocking {
        var store=store();var files=ManagedResourceFiles(context,store);val value=descriptor()
        try {
            catalog(store,listOf(value));retain(files,listOf(value));store.unavailable(room);val plan=files.planUnavailableRetentionRelease()
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            assertEquals(1,files.releaseUnavailableRetention(plan).releasedCount)
            assertEquals(0,files.planUnavailableRetentionRelease().count)
        } finally {files.close();store.close()}
    }
    @Test fun previewRegistryIsBoundedAndExpiredSelectionsAreDiscarded()=runBlocking {
        val store=store()
        try {
            val first=store.planUnavailableRetentionRelease {1000}
            repeat(63) {store.planUnavailableRetentionRelease {1000}}
            assertTrue(runCatching {store.planUnavailableRetentionRelease {1000}}.isFailure)
            assertEquals(0,store.planUnavailableRetentionRelease {61000}.count)
            assertTrue(runCatching {store.releaseUnavailableRetention(first) {61000}}.isFailure)
        } finally {store.close()}
    }
    private suspend fun target(value:ResourceDescriptor)=MediaDownloadTargetClient(object:AuthenticatedTransport {
        override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("not used")
        override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
            put("version",1);put("mode","http_get");put("url","https://provider.invalid/file");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
            put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",5);put("checksum",checksum.payload())
        })})
    }).resolve(value.key.media,MediaMessageLocation((value.key.home as ResourceHome.Room).room,MessageId(id())),null)
    @Test fun sharedRetentionsAndLiveBorrowArePreservedUntilTheirOwnReleaseAndCleanup()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("bytes")});val a=descriptor();val b=descriptor(RoomId(id()))
        val borrowed=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();var use:Job?=null
        try {
            catalog(store,listOf(a));catalog(store,listOf(b));retain(files,listOf(a,b));files.withDownloaded(target(a)) {}
            store.unavailable(room);assertEquals(1,files.releaseUnavailableRetention(files.planUnavailableRetentionRelease()).releasedCount)
            assertTrue(store.resourceFiles().single().retained);files.clearDownloadCache();assertEquals(1,store.resourceFiles().size)
            use=launch {files.withDownloaded(target(b)) {file->borrowed.complete(Unit);gate.await();assertEquals("bytes",file.readText())}}
            borrowed.await();store.unavailable((b.key.home as ResourceHome.Room).room)
            files.releaseUnavailableRetention(files.planUnavailableRetentionRelease());assertFalse(store.resourceFiles().single().retained)
            files.clearDownloadCache();assertEquals(1,store.resourceFiles().size)
            gate.complete(Unit);use.join();files.clearDownloadCache();assertTrue(store.resourceFiles().isEmpty())
        } finally {gate.complete(Unit);use?.cancelAndJoin();files.close();store.close()}
    }
}
