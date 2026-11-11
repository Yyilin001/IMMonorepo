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

class ResourceManagedQuotaTests {
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
    @Test fun legacyPreferencesMigrateToWarningAndOptionalManagedLimitWithoutLosingOtherValues() {
        android.database.sqlite.SQLiteDatabase.create(null).use {db->
            db.execSQL("CREATE TABLE resource_storage_policy(id INTEGER PRIMARY KEY,original_bytes INTEGER NOT NULL,temporary_bytes INTEGER NOT NULL,free_bytes INTEGER NOT NULL,selections INTEGER NOT NULL,cache_bytes INTEGER NOT NULL,cache_entries INTEGER NOT NULL,retained_bytes INTEGER NOT NULL,retained_entries INTEGER NOT NULL)")
            db.execSQL("INSERT INTO resource_storage_policy VALUES(1,65536,32768,1,3,16384,4,8192,5)")
            val preferences=SqliteResourceStoragePolicy(db);val old=preferences.load(ResourceOriginalPolicy())
            assertEquals(8192L,old.retainedWarningBytes);assertNull(old.maximumManagedBytes);assertEquals(3,old.maximumSelections);assertEquals(4,old.maximumCacheEntries)
            preferences.save(old.copy(maximumManagedBytes=123456));assertEquals(123456L,preferences.load(ResourceOriginalPolicy()).maximumManagedBytes)
            preferences.save(old);assertEquals(old,preferences.load(ResourceOriginalPolicy()))
        }
    }
    @Test fun retainedBytesAboveWarningAreAllowedAndGlobalLimitProtectsThem()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(retainedWarningBytes=1),download={t,f->f.writeText(if(t.plan.checksum==hash("one")) "one" else "two")})
        try {
            retain(store,files,"one");files.withDownloaded(target("one")) {};retain(store,files,"two");files.withDownloaded(target("two")) {}
            val before=files.storageSnapshot();assertTrue(before.retainedWarning);assertEquals(2,store.resourceFiles().size);assertEquals(before.retainedAllocatedBytes,before.managedChargedBytes)
            val result=files.setManagedLimit(1);assertTrue(result.cleanupDeferred);assertTrue(result.snapshot.managedOverageBytes>0);assertEquals(2,store.resourceFiles().size)
            assertTrue(runCatching {files.withDownloaded(target("new")) {fail()}}.isFailure)
            files.setManagedLimit(null);assertEquals(before.retainedAllocatedBytes,files.storageSnapshot().retainedAllocatedBytes)
        } finally {files.close();store.close()}
    }
    @Test fun importingOriginalReclaimsOnlyUnretainedCacheForTheManagedLimit()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("cache")) "cache" else "retain")})
        val source=File.createTempFile("managed-original",".txt",context.cacheDir).apply {writeText("original")}
        try {
            files.withDownloaded(target("cache")) {};retain(store,files,"retain");files.withDownloaded(target("retain")) {}
            val before=files.storageSnapshot();files.setManagedLimit(before.managedChargedBytes)
            val asset=files.importFile(source,"original.txt","text/plain",ResourceUsage.Attachment(room),100)
            val after=files.storageSnapshot();assertEquals(0,after.cacheAllocatedBytes);assertEquals(before.retainedAllocatedBytes,after.retainedAllocatedBytes)
            assertTrue(after.originalAllocatedBytes>0);assertTrue(after.managedChargedBytes<=before.managedChargedBytes);files.withOriginal(selection=asset.id) {assertEquals("original",it.readText())}
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun liveTransferIsChargedOnceAndItsUnlimitedAdmissionSurvivesALowerLimit()=runBlocking<Unit> {
        val store=store();val started=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var use:Deferred<String?>?=null
        val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache");started.complete(Unit);finish.await()})
        try {
            use=async {files.withDownloaded(target("cache")) {it.readText()}};started.await();val before=files.storageSnapshot()
            assertEquals(before.transferAllocatedBytes,before.managedChargedBytes);assertTrue(before.temporaryReservedBytes>0)
            assertTrue(files.setManagedLimit(1).cleanupDeferred);finish.complete(Unit);assertEquals("cache",use.await())
            assertEquals(1L,files.storageSnapshot().policy.maximumManagedBytes);assertTrue(files.storageSnapshot().managedOverageBytes>0)
            assertTrue(runCatching {files.withDownloaded(target("new")) {fail()}}.isFailure)
            files.cleanup();assertEquals(0,files.storageSnapshot().managedChargedBytes)
        } finally {finish.complete(Unit);use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun finiteDownloadAdmissionPersistsAcrossOwnerRecreationAndPolicyReduction()=runBlocking<Unit> {
        var store=store();val started=CompletableDeferred<Unit>();var use:Job?=null
        var files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumManagedBytes=65536),download={_,f->File(f.parentFile,f.name+".range-part").writeText("ca");started.complete(Unit);awaitCancellation()})
        try {
            use=launch {files.withDownloaded(target("cache")) {fail()}};started.await();val identity=store.resourceFiles().single().id
            assertTrue(files.setManagedLimit(1).cleanupDeferred);use.cancelAndJoin();files.close();store.close();store=store()
            files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
            assertEquals(1L,files.storageSnapshot().policy.maximumManagedBytes);assertEquals("cache",files.withDownloaded(target("cache")) {it.readText()})
            assertEquals(identity,store.resourceFiles().single().id);files.cleanup();assertEquals(0,files.storageSnapshot().managedChargedBytes)
        } finally {use?.cancelAndJoin();files.close();store.close()}
    }
    @Test fun borrowedCacheCanBeReusedAsOriginalWithoutNewManagedBytesEvenDuringOverage()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
        try {
            files.withDownloaded(target("cache")) {source->
                val before=files.storageSnapshot();assertTrue(files.setManagedLimit(1).cleanupDeferred)
                val asset=files.importFile(source,"same.txt","text/plain",ResourceUsage.Attachment(room),100)
                assertEquals(before.managedChargedBytes,files.storageSnapshot().managedChargedBytes);assertEquals(ResourceFileKind.Original,store.resourceFiles().single().kind)
                assertEquals("cache",source.readText());files.discardSelection(asset.id)
            }
            files.cleanup();assertEquals(0,files.storageSnapshot().managedChargedBytes)
        } finally {files.close();store.close()}
    }
    @Test fun allocatedGrowthCannotPublishAboveManagedLimitAndRecoveryDropsFailedBytes()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumManagedBytes=5))
        val source=File.createTempFile("managed-growth",".txt",context.cacheDir).apply {writeText("cache")}
        try {
            assertTrue(runCatching {files.importFile(source,"tiny.txt","text/plain",ResourceUsage.Attachment(room),100)}.isFailure)
            assertEquals(0,files.storageSnapshot().managedChargedBytes);assertTrue(store.resourceFiles().all {it.state==ResourceFileState.Missing})
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun cacheOverageDoesNotBlockAnUnrelatedOriginalWithoutAManagedLimit()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
        val source=File.createTempFile("managed-independent",".txt",context.cacheDir).apply {writeText("original")}
        try {
            files.withDownloaded(target("cache")) {
                assertTrue(files.setCacheLimit(1).cleanupDeferred)
                val asset=files.importFile(source,"new.txt","text/plain",ResourceUsage.Attachment(room),100)
                files.withOriginal(selection=asset.id) {assertEquals("original",it.readText())}
            }
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun documentStagingAndFutureOriginalMustBothFitAndFailuresRemoveStaging()=runBlocking<Unit> {
        val store=store();val files=ManagedResourceFiles(context,store)
        val source=File.createTempFile("managed-document",".txt",context.filesDir).apply {writeText("source")}
        try {
            val first=files.importFile(source,"source.txt","text/plain",ResourceUsage.Attachment(room),100)
            val oneCopy=files.storageSnapshot().managedChargedBytes;files.discardSelection(first.id);files.cleanup();files.setManagedLimit(oneCopy)
            assertTrue(runCatching {files.importDocument(context.contentResolver,DocumentTestProvider.uri(source),ResourceUsage.Attachment(room))}.isFailure)
            assertEquals(0,files.storageSnapshot().managedChargedBytes)
            assertTrue(File(context.noBackupFilesDir,"resources-${store.resourceScope}/document-imports").listFiles()!!.isEmpty())
            files.setManagedLimit(oneCopy*2);val asset=files.importDocument(context.contentResolver,DocumentTestProvider.uri(source),ResourceUsage.Attachment(room))
            files.withOriginal(selection=asset.id) {assertEquals("source",it.readText())};assertEquals(oneCopy,files.storageSnapshot().managedChargedBytes)
        } finally {files.close();store.close();source.delete()}
    }
    @Test fun acceptedDownloadsCanPublishAfterTheEntryPreferenceIsLowered()=runBlocking<Unit> {
        val store=store();val started=kotlinx.coroutines.channels.Channel<Unit>(2);val finish=CompletableDeferred<Unit>()
        val files=ManagedResourceFiles(context,store,download={t,f->f.writeText(if(t.plan.checksum==hash("one")) "one" else "two");started.send(Unit);finish.await()})
        var first:Deferred<String?>?=null;var second:Deferred<String?>?=null
        try {
            first=async {files.withDownloaded(target("one")) {it.readText()}};second=async {files.withDownloaded(target("two")) {it.readText()}}
            started.receive();started.receive();assertTrue(files.setStoragePolicy(files.storageSnapshot().policy.copy(maximumCacheEntries=1)).cleanupDeferred)
            finish.complete(Unit);assertEquals("one",first.await());assertEquals("two",second.await());assertEquals(2,store.resourceFiles().size)
            files.cleanup();assertEquals(1,store.resourceFiles().size)
        } finally {finish.complete(Unit);first?.cancelAndJoin();second?.cancelAndJoin();files.close();store.close();started.close()}
    }

    @Test fun legacyDownloadWithoutAdmissionRowKeepsItsFormerUnlimitedManagedCredit()=runBlocking<Unit> {
        var store=store();val identity=id()
        store.beginResourceDownload(identity,5,hash("cache"),ResourceOriginalPolicy())
        val path=File(context.noBackupFilesDir,"im-${store.resourceScope}.db");store.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(path.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use {db->db.execSQL("DELETE FROM resource_download_admission")}
        store=store();store.setResourceStoragePolicy(ResourceOriginalPolicy(maximumManagedBytes=1))
        val files=ManagedResourceFiles(context,store,download={_,f->f.writeText("cache")})
        try {
            assertEquals("cache",files.withDownloaded(target("cache")) {it.readText()});assertEquals(identity,store.resourceFiles().single().id)
            assertEquals(1L,files.storageSnapshot().policy.maximumManagedBytes)
        } finally {files.close();store.close()}
    }

    @Test fun missingRetainedBytesDoNotRaiseASoftUsageWarningAfterReconciliation()=runBlocking<Unit> {
        var store=store();var files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(retainedWarningBytes=1),download={_,f->f.writeText("cache")})
        try {
            retain(store,files,"cache");lateinit var path:File;files.withDownloaded(target("cache")) {path=it}
            assertTrue(files.storageSnapshot().retainedWarning);files.close();store.close();check(path.delete())
            store=store();files=ManagedResourceFiles(context,store)
            val after=files.storageSnapshot();assertFalse(after.retainedWarning);assertEquals(0,after.retainedChargedBytes);assertEquals(0,after.managedChargedBytes)
            assertTrue(store.resourceFiles().single().retained);assertEquals(ResourceFileState.Missing,store.resourceFiles().single().state)
        } finally {files.close();store.close()}
    }

}
