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

class ResourceRetentionStorageTests {
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
    @Test fun retentionBeforeDownloadSurvivesReopenCacheClearAndStillRequiresFreshAuthorization()=runBlocking {
        var store=store();var transfers=0;var authorizations=0
        var files=ManagedResourceFiles(context,store,download={_,file->transfers++;file.writeText("abcdefgh")})
        val value=descriptor();val key=ResourceVariantKey(value.key)
        try {
            catalog(store,value);files.setResourceRetained(key,true);assertTrue(store.resourceFiles().isEmpty())
            assertEquals(ResourceVariantSnapshot(ResourceVariantDescriptor(key,hash("abcdefgh"),8),true,false),files.resourceVariants(value.key).single())
            var reader=MessageOriginalFiles({_,_,_->authorizations++;target(value)},store,files)
            reader.withOriginal(value.key) {_,file->assertEquals("abcdefgh",file.readText())};reader.close()
            assertTrue(store.resourceFiles().single().retained);files.clearDownloadCache();files.cleanup()
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store,download={_,_->error("cache hit must not transfer")})
            reader=MessageOriginalFiles({_,_,_->authorizations++;target(value)},store,files)
            reader.withOriginal(value.key,true) {_,file->assertEquals("abcdefgh",file.readText())};reader.close()
            assertEquals(1,transfers);assertEquals(2,authorizations);assertTrue(files.resourceVariants(value.key).single().availableLocally)
        } finally {files.close();store.close()}
    }
    @Test fun sharedBytesStayUntilLastIntentIsReleasedAndRevocationNeverGrantsReading()=runBlocking {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,file->file.writeText("abcdefgh")});val a=descriptor();val b=descriptor()
        try {
            catalog(store,a,b);files.setResourceRetained(ResourceVariantKey(a.key),true);files.setResourceRetained(ResourceVariantKey(b.key),true)
            files.withDownloaded(target(a)) {};files.withDownloaded(target(b)) {};assertEquals(1,store.resourceFiles().size)
            files.setResourceRetained(ResourceVariantKey(a.key),false);files.clearDownloadCache();assertTrue(store.resourceFiles().single().retained)
            store.unavailable(room);assertTrue(files.resourceVariants(b.key).isEmpty());assertNotNull(runCatching {files.setResourceRetained(ResourceVariantKey(a.key),true)}.exceptionOrNull())
            val reader=MessageOriginalFiles({_,_,_->error("revoked source must not authorize")},store,files)
            try {assertNotNull(runCatching {reader.withOriginal(b.key,true) {_,_->fail()}}.exceptionOrNull())} finally {reader.close()}
            files.clearDownloadCache();assertEquals(1,store.resourceFiles().size)
            files.setResourceRetained(ResourceVariantKey(b.key),false);files.clearDownloadCache();assertTrue(store.resourceFiles().isEmpty())
        } finally {files.close();store.close()}
    }
    @Test fun retainedQuotaIsSeparateAndFailedPromotionRollsBackWithoutEvictingAnything()=runBlocking {
        val store=store();val a=descriptor();val b=descriptor("second")
        val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumCacheBytes=65536,maximumCacheEntries=1,retainedWarningBytes=65536,maximumRetainedEntries=1),download={target,file->file.writeText(if(target.plan.expectedBytes==8L) "abcdefgh" else "second")})
        try {
            catalog(store,a,b);files.setResourceRetained(ResourceVariantKey(a.key),true);files.withDownloaded(target(a)) {}
            files.withDownloaded(target(b,"second")) {};assertEquals(2,store.resourceFiles().size)
            assertNotNull(runCatching {files.setResourceRetained(ResourceVariantKey(b.key),true)}.exceptionOrNull())
            assertFalse(files.resourceVariants(b.key).single().retained);assertTrue(files.resourceVariants(a.key).single().retained);assertEquals(2,store.resourceFiles().size)
            files.setResourceRetained(ResourceVariantKey(a.key),false);files.setResourceRetained(ResourceVariantKey(b.key),true);files.clearDownloadCache()
            assertEquals(1,store.resourceFiles().size);assertEquals(hash("second"),store.resourceFiles().single().checksum)
        } finally {files.close();store.close()}
    }
    @Test fun originalOwnershipAndVariantRetentionHaveIndependentLifetimes()=runBlocking {
        val store=store();val value=descriptor();val files=ManagedResourceFiles(context,store,download={_,file->file.writeText("abcdefgh")})
        try {
            catalog(store,value);files.setResourceRetained(ResourceVariantKey(value.key),true)
            val asset=files.withDownloaded(target(value)) {files.importFile(it,"副本.txt","text/plain",ResourceUsage.Attachment(room),1024)}!!
            assertEquals(ResourceFileKind.Original,store.resourceFiles().single().kind)
            files.discardSelection(asset.id);files.cleanup();assertEquals(ResourceFileKind.Cache,store.resourceFiles().single().kind);assertTrue(store.resourceFiles().single().retained)
            files.clearDownloadCache();assertEquals(1,store.resourceFiles().size)
            files.setResourceRetained(ResourceVariantKey(value.key),false);files.clearDownloadCache();assertTrue(store.resourceFiles().isEmpty())
        } finally {files.close();store.close()}
    }
    @Test fun derivedVersionsAreImmutableSeparatelyRetainedAndLateMetadataIsRejected()=runBlocking {
        val store=store();val value=descriptor();val files=ManagedResourceFiles(context,store)
        try {
            catalog(store,value);val read=store.selectMessageResource(value.key);val rendition=id()
            val first=ResourceVariantDescriptor(ResourceVariantKey(value.key,ResourceRendition.Derived(rendition,1)),hash("thumb"),5)
            store.observeResourceVariant(read,target(value,"thumb",first));files.setResourceRetained(first.key,true)
            val second=first.copy(key=first.key.copy(rendition=ResourceRendition.Derived(rendition,2)),checksum=hash("large"))
            store.observeResourceVariant(read,target(value,"large",second));assertFalse(files.resourceVariants(value.key).first {it.descriptor.key==second.key}.retained)
            assertNotNull(runCatching {store.observeResourceVariant(read,target(value,"other",first.copy(checksum=hash("other"))))}.exceptionOrNull())
            store.unavailable(room);assertNotNull(runCatching {store.observeResourceVariant(read,target(value,"large",second))}.exceptionOrNull())
            files.setResourceRetained(first.key,false)
        } finally {files.close();store.close()}
    }
    @Test fun corruptedRetainedBytesAreRemovedButIntentSurvivesForVerifiedRedownload()=runBlocking {
        val store=store();val value=descriptor();var transfers=0
        val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumRetainedEntries=1),download={_,file->transfers++;file.writeText("abcdefgh")})
        try {
            catalog(store,value);files.setResourceRetained(ResourceVariantKey(value.key),true)
            files.withDownloaded(target(value)) {Os.chmod(it.path,384);it.writeText("corrupt!")}
            assertNull(files.withDownloaded(target(value),true) {error("corruption reached reader")})
            assertEquals(ResourceFileState.Invalid,store.resourceFiles().single().state);assertTrue(files.resourceVariants(value.key).single().retained)
            assertEquals("abcdefgh",files.withDownloaded(target(value)) {it.readText()});assertEquals(2,transfers)
            assertTrue(store.resourceFiles().single().retained);files.cleanup();assertTrue(files.resourceVariants(value.key).single().availableLocally)
        } finally {files.close();store.close()}
    }
    @Test fun interruptedRetainedPublicationRecoversEvenIfQuotaWasReduced()=runBlocking {
        var store=store();val value=descriptor()
        var files=ManagedResourceFiles(context,store,checkpoint={if(it==ManagedResourceFiles.PublicationCheckpoint.Copied) error("interrupted")},download={_,file->file.writeText("abcdefgh")})
        try {
            catalog(store,value);files.setResourceRetained(ResourceVariantKey(value.key),true)
            assertNotNull(runCatching {files.withDownloaded(target(value)) {fail()}}.exceptionOrNull());files.close();store.close()
            store=store();store.setResourceStoragePolicy(ResourceOriginalPolicy(retainedWarningBytes=1));files=ManagedResourceFiles(context,store,download={_,_->error("already written")})
            assertEquals("abcdefgh",files.withDownloaded(target(value),true) {it.readText()});files.cleanup();files.clearDownloadCache()
            assertTrue(store.resourceFiles().single().retained);assertTrue(files.resourceVariants(value.key).single().availableLocally)
            files.setResourceRetained(ResourceVariantKey(value.key),false);files.clearDownloadCache();assertTrue(store.resourceFiles().isEmpty())
        } finally {files.close();store.close()}
    }
}
