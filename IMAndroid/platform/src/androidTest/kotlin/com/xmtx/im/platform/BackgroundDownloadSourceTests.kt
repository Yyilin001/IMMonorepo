package com.xmtx.im.platform

import android.system.Os
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

class BackgroundDownloadSourceTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture(policy:ResourceOriginalPolicy=ResourceOriginalPolicy(minimumFreeBytes=0),checkpoint:(ManagedResourceFiles.PublicationCheckpoint)->Unit={}) {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val body=ByteArray(8192) {(it%251).toByte()}
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"原件.dat","application/octet-stream",body.size.toLong(),
            ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(body).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
        var store=SqliteClientStore(context,actor,device)
        var files=ManagedResourceFiles(context,store,policy,checkpoint=checkpoint,download={_,file->file.writeBytes(body)})
        val inbox=ResourceBackgroundDownloadInbox(context,store.resourceScope)
        val root=File(context.noBackupFilesDir,"resources-${store.resourceScope}/background-downloads")
        lateinit var mapping:ResourceBackgroundDownloadMapping
        suspend fun target():MediaDownloadTarget {
            val now=System.currentTimeMillis();val grant=ResourceBackgroundDownloadAuthorization(id(),body.size.toLong(),descriptor.checksum!!,now,now+60000)
            return MediaDownloadTargetClient(object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unused")
                override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url","https://objects.invalid/original?secret=delegation");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                    put("expiresAtUnixMilliseconds",grant.expiresAt);put("expectedByteCount",grant.expectedBytes);put("checksum",grant.checksum.payload());put("backgroundDownloadAuthorization",grant.payload())
                })})
            }).resolve(descriptor.key.media,null,null)
        }
        suspend fun install() {
            store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100,0,descriptor.key.media),1000,descriptor)),100,null))
            val job=store.enqueueResourceDownload(descriptor.key,store.resourceSources(descriptor.key).sources.single())
            val claim=store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!
            mapping=store.installBackgroundDownload(claim,id(),id(),ResourceBackgroundDownloadTarget(target()))
        }
        suspend fun receive(bytes:ByteArray=body) {inbox.receive(mapping,mapping.originDigest) {it.write(bytes)}}
        suspend fun finish() {assertTrue(store.finishBackgroundDownload(mapping,ResourceBackgroundDownloadResult(mapping.id,mapping.task,200,null,body.size.toLong(),mapping.originDigest)))}
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store,download={_,_->error("received bytes must not be downloaded again")})}
        suspend fun complete() {assertTrue(store.completeBackgroundDownload(mapping,store.selectMessageResource(descriptor.key)));files.releaseBackgroundDownloadSource(mapping)}
        suspend fun close() {files.close();store.close()}
    }
    @Test fun coldWriterReceivesWithoutAccountDatabaseAndReopenedOwnerPublishesAfterFreshTarget()=runBlocking {
        val f=Fixture()
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            val promised=f.files.storageSnapshot().temporaryReservedBytes;assertTrue(promised>=f.body.size*2L)
            assertNull(f.files.withDownloaded(f.target(),cacheOnly=true) {it.length()})
            f.files.close();f.store.close();f.receive() // No account database or file owner is open while the inbox receives.
            f.store=SqliteClientStore(context,f.actor,f.device);f.files=ManagedResourceFiles(context,f.store,download={_,_->error("no HTTP")})
            assertTrue(f.files.storageSnapshot().temporaryReservedBytes>=promised)
            f.finish();f.files.publishBackgroundDownload(f.mapping,f.target())
            assertArrayEquals(f.body,f.files.withDownloaded(f.target(),cacheOnly=true) {it.readBytes()})
            f.complete();assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);assertFalse(File(f.root,f.mapping.id).exists())
            assertTrue(runCatching {f.receive()}.isFailure);assertFalse(File(f.root,f.mapping.id).exists())
        } finally {f.close()}
    }
    @Test fun rawAndPublicationReservationRejectsBothTemporaryAndManagedOvercommit()=runBlocking {
        val f=Fixture(ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=16384,maximumManagedBytes=16384))
        try {
            f.install();assertTrue(runCatching {f.files.prepareBackgroundDownloadSource(f.mapping)}.isFailure)
            assertTrue(f.store.backgroundDownloadSources().isEmpty());assertFalse(f.root.exists())
            f.files.setStoragePolicy(ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=65536,maximumManagedBytes=16384))
            assertTrue(runCatching {f.files.prepareBackgroundDownloadSource(f.mapping)}.isFailure);assertTrue(f.store.backgroundDownloadSources().isEmpty())
            f.files.setStoragePolicy(ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=65536,maximumManagedBytes=65536))
            f.files.prepareBackgroundDownloadSource(f.mapping)
            val charged=f.files.storageSnapshot().temporaryReservedBytes
            assertTrue(runCatching {f.store.beginResourceDownload(id(),40000,ResourceChecksum("a".repeat(64)),ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=65536,maximumManagedBytes=65536))}.isFailure)
            assertEquals(charged,f.files.storageSnapshot().temporaryReservedBytes)
            assertTrue(f.store.finishBackgroundDownload(f.mapping,null));f.files.releaseBackgroundDownloadSource(f.mapping);assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {f.close()}
    }
    @Test fun exactByteWriterRejectsShortOverflowAndWrongOriginAndPublicationRejectsWrongHash()=runBlocking {
        val f=Fixture()
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping);var entered=false
            assertTrue(runCatching {f.inbox.receive(f.mapping,"b".repeat(64)) {entered=true}}.isFailure);assertFalse(entered)
            assertTrue(runCatching {f.receive(f.body.copyOf(f.body.size-1))}.isFailure)
            assertTrue(runCatching {f.receive(f.body.copyOf(f.body.size+1))}.isFailure)
            assertFalse(File(f.root,"${f.mapping.id}/incoming").exists());assertFalse(File(f.root,"${f.mapping.id}/data").exists())
            f.receive(ByteArray(f.body.size));f.finish()
            assertTrue(runCatching {f.files.publishBackgroundDownload(f.mapping,f.target())}.exceptionOrNull() is InvalidResourceBytes)
            assertTrue(f.store.resourceFiles().none {it.state==ResourceFileState.Published})
            assertTrue(f.store.discardReceivedBackgroundDownload(f.mapping,ResourceDownloadIssue.Integrity));f.files.releaseBackgroundDownloadSource(f.mapping)
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {f.close()}
    }
    @Test fun systemWriterLockPreventsDeletionEvenIfCallerIncorrectlyClaimsDrain()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var writer:Job?=null
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping)
            writer=launch(Dispatchers.IO) {f.inbox.receive(f.mapping,f.mapping.originDigest) {out->out.write(f.body);entered.complete(Unit);release.await()}}
            withTimeout(5000) {entered.await()}
            assertTrue(runCatching {f.files.releaseBackgroundDownloadSource(f.mapping)}.isFailure)
            assertTrue(f.store.finishBackgroundDownload(f.mapping,null))
            assertTrue(runCatching {f.files.releaseBackgroundDownloadSource(f.mapping)}.isFailure)
            assertTrue(f.store.backgroundDownloadSources().single().deleting)
            release.complete(Unit);writer.join();f.reopen()
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);assertTrue(f.store.backgroundDownloadSources().isEmpty())
            assertTrue(runCatching {f.receive()}.isFailure)
        } finally {release.complete(Unit);writer?.cancelAndJoin();f.close()}
    }
    @Test fun symbolicLinksCannotReadOrOverwriteFilesOutsideTheInbox()=runBlocking {
        val f=Fixture();val external=File.createTempFile("inbox-external-",".dat",context.cacheDir).apply {writeText("preserve")}
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping);val incoming=File(f.root,"${f.mapping.id}/incoming")
            Os.symlink(external.path,incoming.path);assertTrue(runCatching {f.receive()}.isFailure);assertEquals("preserve",external.readText());Os.remove(incoming.path)
            val data=File(f.root,"${f.mapping.id}/data");Os.symlink(external.path,data.path)
            assertTrue(runCatching {f.inbox.withReceived(f.mapping) {it.readBytes()}}.isFailure);assertEquals("preserve",external.readText());Os.remove(data.path)
            f.store.finishBackgroundDownload(f.mapping,null);f.files.releaseBackgroundDownloadSource(f.mapping)
        } finally {external.delete();f.close()}
    }
    @Test fun publicationCrashAtEveryBoundaryKeepsRawBytesAndRecoversWithoutAnotherTransfer()=runBlocking {
        for(phase in ManagedResourceFiles.PublicationCheckpoint.entries) {
            val f=Fixture(checkpoint={if(it==phase) error("simulated publication interruption")})
            try {
                f.install();f.files.prepareBackgroundDownloadSource(f.mapping);f.receive();f.finish()
                assertTrue(runCatching {f.files.publishBackgroundDownload(f.mapping,f.target())}.isFailure)
                assertTrue(File(f.root,"${f.mapping.id}/data").exists());f.reopen()
                f.files.publishBackgroundDownload(f.mapping,f.target());assertArrayEquals(f.body,f.files.withDownloaded(f.target(),cacheOnly=true) {it.readBytes()})
                f.complete();assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
            } finally {f.close()}
        }
    }
    @Test fun admittedPublicationSurvivesQuotaReductionAndCanReuseVerifiedCache()=runBlocking {
        val f=Fixture(ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=131072,maximumCacheBytes=131072,maximumManagedBytes=131072))
        try {
            f.install();f.files.withDownloaded(f.target()) {};val cached=f.store.resourceFiles().single().id
            f.files.prepareBackgroundDownloadSource(f.mapping);f.receive();f.finish();f.files.publishBackgroundDownload(f.mapping,f.target())
            assertEquals(cached,f.store.backgroundDownloadSources().single().publication);assertEquals(1,f.store.resourceFiles().size)
            f.files.setStoragePolicy(ResourceOriginalPolicy(minimumFreeBytes=0,maximumTemporaryBytes=1,maximumCacheBytes=1,maximumManagedBytes=1))
            // Cleanup may evict the idle cache; the received raw source remains and can rearm its publication.
            assertTrue(File(f.root,"${f.mapping.id}/data").exists());f.files.publishBackgroundDownload(f.mapping,f.target())
            assertArrayEquals(f.body,f.files.withDownloaded(f.target(),cacheOnly=true) {it.readBytes()});f.complete()
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {f.close()}
    }
    @Test fun revocationAfterReceiptCannotPublishOrPrematurelyReleaseItsSource()=runBlocking {
        val f=Fixture()
        try {
            f.install();f.files.prepareBackgroundDownloadSource(f.mapping);f.receive();f.finish();f.store.unavailable(f.room)
            assertTrue(runCatching {f.files.publishBackgroundDownload(f.mapping,f.target())}.isFailure)
            assertTrue(f.store.resourceFiles().none {it.state==ResourceFileState.Published})
            assertTrue(runCatching {f.files.releaseBackgroundDownloadSource(f.mapping)}.isFailure)
            assertTrue(f.store.finishBackgroundDownload(f.mapping,null));f.files.releaseBackgroundDownloadSource(f.mapping)
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {f.close()}
    }
}
