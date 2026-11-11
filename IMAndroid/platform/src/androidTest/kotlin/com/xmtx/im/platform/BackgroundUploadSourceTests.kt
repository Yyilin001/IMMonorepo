package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class BackgroundUploadSourceTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture(val checkpoint:(ManagedResourceFiles.BackgroundSourceCheckpoint)->Unit={}) {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store,backgroundCheckpoint=checkpoint)
        val source=File.createTempFile("background-journal-",".txt",context.cacheDir).apply {writeText("0123456789")}
        suspend fun prepare():ResourceUploadClaim {
            val asset=files.importFile(source,"记录.txt","text/plain",ResourceUsage.Attachment(room),1024)
            val work=store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut),asset.displayName))
            val owner=id();val create=store.claimResourceUpload(work.id,owner,now)!!
            val remote=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),work.request.media,1,ResourceSessionState.Created,ResourceState.Pending,10_000_000,null,persistentListOf(),null)
            store.finishResourceUpload(create,remote,ResourceUploadAction.Upload,now)
            return store.claimResourceUpload(work.id,owner,now)!!
        }
        suspend fun next(upload:String):ResourceUploadClaim {
            val work=store.resourceUploads().first {it.id==upload};now=maxOf(now,work.execution.retryAt)
            val status=store.claimResourceUpload(upload,id(),now)!!
            store.finishResourceUpload(status,work.session,ResourceUploadAction.Upload,now)
            return store.claimResourceUpload(upload,id(),now)!!
        }
        suspend fun registrations(claim:ResourceUploadClaim,parts:Boolean=false):PersistentList<ResourceBackgroundUploadRegistration> {
            val session=claim.work.session!!;val request=claim.work.request
            val plans=(if(parts) listOf(1,2) else listOf(0)).map {number->
                val scope=if(number==0) ResourceBackgroundUploadScope.Whole(request.byteCount,request.checksum) else ResourceBackgroundUploadScope.Part(number)
                val grant=ResourceBackgroundUploadAuthorization(id(),session.locator.session,session.generation,request.media,scope,now,now+60000)
                buildJsonObject {
                    put("version",1);put("mode",if(parts) "http_part_put" else "http_put");put("url","https://objects.example.test/private?cap=NEVER-PERSIST-THIS")
                    put("headers",JsonArray(emptyList()));put("formFields",buildJsonObject {});put("expiresAtUnixMilliseconds",grant.expiresAt)
                    put("expectedByteCount",if(parts) 5 else 10)
                    if(parts) {put("partNumber",number);put("byteRange",ResourceRange((number-1)*5L,number*5L-1).payload())} else put("checksum",request.checksum.payload())
                    put("backgroundAuthorization",grant.payload())
                }
            }
            val api=object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unexpected request")
                override suspend fun requestArray(path:String,payload:JsonObject,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {},arrayBody=JsonArray(plans))
            }
            val targets=ResourceUploadClient(api,actor,{now},{1000}).backgroundTargets(session,request,if(parts) persistentListOf(1,2) else persistentListOf())
            return targets.map {ResourceBackgroundUploadRegistration(id(),id(),it)}.toPersistentList()
        }
        suspend fun install(claim:ResourceUploadClaim,parts:Boolean=false)=store.installBackgroundUploads(claim,registrations(claim,parts),now)
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store,backgroundCheckpoint=checkpoint)}
        suspend fun close() {files.close();store.close();source.delete()}
    }
    @Test fun wholeAndExactSlicesSurviveReopenAndOrdinaryCleanup()=runBlocking {
        val f=Fixture()
        try {
            val claim=f.prepare();val mappings=f.install(claim,true)
            for(m in mappings) f.files.prepareBackgroundUploadSource(m)
            val before=f.files.storageSnapshot();assertTrue(before.temporaryReservedBytes>=20);assertTrue(before.transferAllocatedBytes>0)
            val paths=mappings.mapIndexed {index,m->f.files.withBackgroundUploadSource(m) {file->
                assertEquals(if(index==0) "01234" else "56789",file.readText())
                assertTrue(file.canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath+"/"))
                assertEquals(0,android.system.Os.lstat(file.path).st_mode and 0x92);file.path
            }}
            f.reopen();f.files.cleanup();f.files.commitCacheCleanup(f.files.planCacheCleanup())
            assertEquals(before.temporaryReservedBytes,f.files.storageSnapshot().temporaryReservedBytes)
            for((index,m) in mappings.withIndex()) {
                f.files.prepareBackgroundUploadSource(m)
                f.files.withBackgroundUploadSource(m) {assertEquals(paths[index],it.path)}
                assertTrue(runCatching {f.files.releaseBackgroundUploadSource(m)}.isFailure)
                assertTrue(f.store.completeBackgroundUpload(m,null,f.now));f.files.releaseBackgroundUploadSource(m)
                assertFalse(File(paths[index]).exists())
            }
            assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
            val whole=f.prepare();val m=f.install(whole).single();f.files.prepareBackgroundUploadSource(m)
            f.files.withBackgroundUploadSource(m) {assertEquals(f.source.readText(),it.readText())}
            assertTrue(f.store.completeBackgroundUpload(m,null,f.now));f.files.releaseBackgroundUploadSource(m)
            f.files.withOriginal(upload=whole.work.id) {assertEquals(f.source.readText(),it.readText())}
        } finally {f.close()}
    }
    @Test fun cancelledTaskAndLiveBorrowBothFenceDeletionAndCloseWaitsForDrain()=runBlocking {
        val f=Fixture();val entered=CompletableDeferred<Unit>();val drain=CompletableDeferred<Unit>()
        try {
            val claim=f.prepare();val m=f.install(claim).single();f.files.prepareBackgroundUploadSource(m)
            val borrow=launch {f.files.withBackgroundUploadSource(m) {entered.complete(Unit);drain.await();assertEquals("0123456789",it.readText())}}
            entered.await();f.store.requestResourceUploadCancellation(claim.work.id)
            assertTrue(runCatching {f.files.releaseBackgroundUploadSource(m)}.isFailure)
            assertTrue(f.store.completeBackgroundUpload(m,null,f.now))
            assertTrue(runCatching {f.files.releaseBackgroundUploadSource(m)}.isFailure)
            val closing=async {f.files.close()};delay(50);assertFalse(closing.isCompleted)
            drain.complete(Unit);borrow.join();closing.await()
            f.store.close();f.store=SqliteClientStore(context,f.actor,f.device);f.files=ManagedResourceFiles(context,f.store)
            assertTrue(f.files.storageSnapshot().temporaryReservedBytes>0)
            f.files.releaseBackgroundUploadSource(m);assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
        } finally {drain.complete(Unit);f.close()}
    }
    @Test fun otherAccountAndTamperedIdentityCannotAdoptOrDeleteSources()=runBlocking {
        val f=Fixture();val other=Fixture()
        try {
            val m=f.install(f.prepare()).single();f.files.prepareBackgroundUploadSource(m)
            assertTrue(runCatching {other.files.prepareBackgroundUploadSource(m)}.isFailure)
            assertTrue(runCatching {other.files.withBackgroundUploadSource(m) {error("must not borrow")}}.isFailure)
            val changed=m.copy(task=id())
            assertTrue(runCatching {f.files.prepareBackgroundUploadSource(changed)}.isFailure)
            assertTrue(runCatching {f.files.releaseBackgroundUploadSource(changed)}.isFailure)
            f.files.withBackgroundUploadSource(m) {assertEquals("0123456789",it.readText())}
        } finally {other.close();f.close()}
    }
    @Test fun interruptedPublicationOnlyReclaimsUnpublishedBytesAndKeepsMapping()=runBlocking {
        for(phase in listOf(ManagedResourceFiles.BackgroundSourceCheckpoint.Reserved,ManagedResourceFiles.BackgroundSourceCheckpoint.Copied,ManagedResourceFiles.BackgroundSourceCheckpoint.Renamed,ManagedResourceFiles.BackgroundSourceCheckpoint.Ready)) {
            var failed=false
            val f=Fixture {if(it==phase && !failed) {failed=true;throw java.io.IOException("injected publication interruption")}}
            try {
                val m=f.install(f.prepare()).single();assertTrue(runCatching {f.files.prepareBackgroundUploadSource(m)}.isFailure)
                f.reopen();val usage=f.files.storageSnapshot()
                assertEquals(listOf(m),f.store.activeBackgroundUploads())
                if(phase==ManagedResourceFiles.BackgroundSourceCheckpoint.Ready) assertTrue(usage.temporaryReservedBytes>0) else assertEquals(0L,usage.temporaryReservedBytes)
                f.files.prepareBackgroundUploadSource(m);f.files.withBackgroundUploadSource(m) {assertEquals("0123456789",it.readText())}
            } finally {f.close()}
        }
    }
    @Test fun interruptedDeletionIsFinishedAfterReopenWithoutResurrectingQuotaOrBytes()=runBlocking {
        for(phase in listOf(ManagedResourceFiles.BackgroundSourceCheckpoint.Deleting,ManagedResourceFiles.BackgroundSourceCheckpoint.Unlinked)) {
            var failed=false
            val f=Fixture {if(it==phase && !failed) {failed=true;throw java.io.IOException("injected deletion interruption")}}
            try {
                val m=f.install(f.prepare()).single();f.files.prepareBackgroundUploadSource(m)
                val path=f.files.withBackgroundUploadSource(m) {it.path}
                assertTrue(f.store.completeBackgroundUpload(m,null,f.now))
                assertTrue(runCatching {f.files.releaseBackgroundUploadSource(m)}.isFailure)
                f.reopen();assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes);assertFalse(File(path).exists())
                f.files.releaseBackgroundUploadSource(m)
            } finally {f.close()}
        }
    }
    @Test fun corruptMissingAndSymlinkSourcesFailClosedAndReleaseDoesNotFollowLinks()=runBlocking {
        for(kind in listOf("corrupt","missing","symlink")) {
            val f=Fixture();val external=File.createTempFile("background-external-",".txt",context.cacheDir).apply {writeText("external unchanged")}
            try {
                val m=f.install(f.prepare()).single();f.files.prepareBackgroundUploadSource(m)
                val path=f.files.withBackgroundUploadSource(m) {it.path};val file=File(path)
                if(kind=="corrupt") {android.system.Os.chmod(path,384);file.writeText("9876543210")} else {assertTrue(file.delete());if(kind=="symlink") android.system.Os.symlink(external.path,path)}
                f.reopen();assertTrue(runCatching {f.files.withBackgroundUploadSource(m) {error("must not expose invalid bytes")}}.exceptionOrNull() is InvalidResourceBytes)
                assertTrue(f.store.completeBackgroundUpload(m,null,f.now));f.files.releaseBackgroundUploadSource(m)
                assertFalse(file.exists());assertEquals("external unchanged",external.readText())
            } finally {external.delete();f.close()}
        }
    }
    @Test fun journalAdmissionAlsoIncludesDurableBackgroundDebtForImportsAndDownloads()=runBlocking {
        val f=Fixture()
        try {
            val m=f.install(f.prepare()).single();f.files.prepareBackgroundUploadSource(m)
            val snapshot=f.files.storageSnapshot();val original=f.store.resourceAssets().single()
            val imported=original.copy(id=id(),plannedFile=id(),file=null,availability=ResourceAssetAvailability.Importing)
            val temporary=snapshot.policy.copy(maximumTemporaryBytes=snapshot.temporaryReservedBytes+9)
            val managed=snapshot.policy.copy(maximumManagedBytes=snapshot.managedChargedBytes+9)
            for(policy in listOf(temporary,managed)) {
                assertTrue(runCatching {f.store.beginResourceImport(imported,policy)}.isFailure)
                assertTrue(runCatching {f.store.beginResourceDownload(id(),10,original.checksum,policy)}.isFailure)
            }
            assertEquals(listOf(original),f.store.resourceAssets());assertEquals(1,f.store.resourceFiles().size)
            assertEquals(snapshot.managedChargedBytes,f.files.storageSnapshot().managedChargedBytes)
        } finally {f.close()}
    }
    @Test fun temporaryAdmissionAndManagedQuotaChargeCopiesWithoutEvictingLiveSources()=runBlocking {
        val f=Fixture()
        try {
            val m=f.install(f.prepare()).single();val before=f.files.storageSnapshot()
            f.files.setStoragePolicy(before.policy.copy(maximumTemporaryBytes=19))
            assertTrue(runCatching {f.files.prepareBackgroundUploadSource(m)}.isFailure);assertEquals(0L,f.files.storageSnapshot().temporaryReservedBytes)
            f.files.setStoragePolicy(before.policy.copy(maximumManagedBytes=before.managedChargedBytes+19))
            assertTrue(runCatching {f.files.prepareBackgroundUploadSource(m)}.isFailure)
            f.files.setStoragePolicy(before.policy);f.files.prepareBackgroundUploadSource(m)
            val reserved=f.files.storageSnapshot();assertTrue(reserved.temporaryReservedBytes>=20)
            val reduced=f.files.setManagedLimit(before.managedChargedBytes)
            assertTrue(reduced.cleanupDeferred);assertTrue(reduced.snapshot.managedOverageBytes>0)
            f.reopen();f.files.withBackgroundUploadSource(m) {assertEquals("0123456789",it.readText())}
            f.source.writeText("abcdefghij");assertTrue(runCatching {f.prepare()}.isFailure)
            assertTrue(f.store.completeBackgroundUpload(m,null,f.now));f.files.releaseBackgroundUploadSource(m)
            assertEquals(before.managedChargedBytes,f.files.storageSnapshot().managedChargedBytes)
        } finally {f.close()}
    }
}
