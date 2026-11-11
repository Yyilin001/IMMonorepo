package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import android.system.Os
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ResourceFilesStorageTests {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun source()=File.createTempFile("resource-files-test-",".txt",context.filesDir).apply { writeText("不可变原文件\n") }
    private suspend fun imported(files: ManagedResourceFiles,file: File,name: String="附件.txt",id: String=id()) = files.importFile(file,name,"text/plain",ResourceUsage.UserAvatar,1024,id)
    private fun request(asset: ResourceLocalAsset)=ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,modes=persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut),displayName=asset.displayName)
    private fun session(work: ResourceUploadWork,state: ResourceSessionState=ResourceSessionState.Uploading)=ResourceUploadSession(ResourceUploadLocator(work.request.usage.home(actor),id()),work.request.media,1,state,ResourceState.Pending,2000000000000,null,persistentListOf(),null)
    private suspend fun fails(block: suspend ()->Unit) { var failure: Throwable?=null;try { block() } catch(error: Exception) { failure=error };assertNotNull(failure) }

    @Test fun deduplicatedSelectionsAndAtomicUploadClaimsKeepOriginalUntilExplicitRelease()=runBlocking {
        val source=source();val store=store();val files=ManagedResourceFiles(context,store)
        try {
            val first=imported(files,source);val second=imported(files,source,"另一个名称.txt")
            assertNotEquals(first.id,second.id);assertEquals(first.file,second.file);assertEquals(1,store.resourceFiles().size)
            val request=request(first);val work=store.prepareResourceUpload(id(),first.id,request)
            assertEquals(work,store.prepareResourceUpload(work.id,first.id,request));assertFalse(store.resourceAssets().first { it.id==first.id }.selectionActive)
            files.discardSelection(second.id);files.cleanup();assertEquals(1,store.resourceFiles().size)
            files.withOriginal(upload=work.id) { assertEquals(source.readText(),it.readText()) }
            fails { files.withOriginal(selection=first.id) { } };fails { store.releaseResourceUploadSource(work.id) }
            store.requestResourceUploadCancellation(work.id);fails { store.saveResourceUploadSession(work.id,session(work)) }
            store.confirmResourceUploadCancellation(work.id,session(work,ResourceSessionState.Cancelled));store.releaseResourceUploadSource(work.id)
            files.cleanup();assertTrue(store.resourceFiles().isEmpty());assertTrue(store.resourceUploads().single().sourceReleased)
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun physicalLeaseSurvivesSelectionRemovalCleanupAndOwnerCloseWaitsForDrain()=runBlocking {
        val source=source();val store=store();val files=ManagedResourceFiles(context,store);val secondOwner=ManagedResourceFiles(context,store)
        try {
            val asset=imported(files,source);fails { secondOwner.selected(ResourceUsage.UserAvatar) }
            val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val borrowing=launch { files.withOriginal(selection=asset.id) { file ->
                files.discardSelection(asset.id);files.cleanup();assertTrue(file.exists());entered.complete(Unit);release.await();assertEquals(source.readText(),file.readText())
            } }
            entered.await();val closing=launch { files.close() };yield();assertFalse(closing.isCompleted)
            release.complete(Unit);withTimeout(5000) { borrowing.join();closing.join() }
            assertTrue(secondOwner.selected(ResourceUsage.UserAvatar).isEmpty());secondOwner.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();secondOwner.close();store.close();source.delete() }
    }
    @Test fun journalBeforeRenameNeverPublishesPartialButRenamedBytesRecoverOriginalIdentity()=runBlocking {
        val source=source()
        for(point in ManagedResourceFiles.PublicationCheckpoint.entries) {
            var store=SqliteClientStore(context,actor,DeviceId(id()));var files=ManagedResourceFiles(context,store,checkpoint={ if(it==point) throw java.io.IOException("simulated process interruption") })
            try {
                val selection=id();fails { imported(files,source,id=selection) };files.close()
                // Same account database and file owner, with the fault injector removed.
                files=ManagedResourceFiles(context,store)
                val recovered=files.selected(ResourceUsage.UserAvatar).single();assertEquals(selection,recovered.id)
                if(point in setOf(ManagedResourceFiles.PublicationCheckpoint.Renamed,ManagedResourceFiles.PublicationCheckpoint.Published)) {
                    assertEquals(ResourceAssetAvailability.Local,recovered.availability);files.withOriginal(selection=selection) { assertEquals(source.readText(),it.readText()) }
                } else { assertEquals(ResourceAssetAvailability.Unavailable,recovered.availability);fails { files.withOriginal(selection=selection) { } } }
                files.discardSelection(selection);files.cleanup();assertTrue(store.resourceFiles().isEmpty())
            } finally { files.close();store.close() }
        }
        source.delete();Unit
    }
    @Test fun cancelledImportReleasesSelectionAndCanBeReconciledWithoutExternalPath()=runBlocking {
        val source=source();val store=store();var files=ManagedResourceFiles(context,store,checkpoint={ if(it==ManagedResourceFiles.PublicationCheckpoint.Copied) throw CancellationException("cancelled selection") })
        try {
            fails { imported(files,source) };assertFalse(store.resourceAssets().single().selectionActive);files.close();source.delete()
            files=ManagedResourceFiles(context,store);assertTrue(files.selected(ResourceUsage.UserAvatar).isEmpty());files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun corruptedAndSymlinkedOriginalsAreNeverBorrowedAndCleanupDoesNotFollowTargets()=runBlocking {
        val source=source();val store=store();val files=ManagedResourceFiles(context,store)
        try {
            val first=imported(files,source);lateinit var original: File
            files.withOriginal(selection=first.id) { original=it };Os.chmod(original.path,384);original.writeBytes(ByteArray(source.length().toInt()) { 1 })
            fails { files.withOriginal(selection=first.id) { fail() } };assertEquals(ResourceFileState.Invalid,store.resourceFiles().single().state)
            val second=imported(files,source);assertNotEquals(first.file,second.file)
            lateinit var other: File;files.withOriginal(selection=second.id) { other=it };Os.remove(other.path);Os.symlink(source.path,other.path)
            fails { files.withOriginal(selection=second.id) { fail() } };files.discardSelection(first.id);files.discardSelection(second.id);files.cleanup()
            assertTrue(source.exists());assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun selectionAndAllocatedByteLimitsRejectNewFilesWithoutEvictingExistingOriginals()=runBlocking {
        val source=source();val store=store();var files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumSelections=1))
        try {
            val first=imported(files,source);fails { imported(files,source) };assertEquals(1,store.resourceAssets().size)
            files.discardSelection(first.id);files.cleanup();files.close()
            store.setResourceStoragePolicy(ResourceOriginalPolicy(maximumOriginalBytes=source.length(),maximumTemporaryBytes=source.length()))
            files=ManagedResourceFiles(context,store,ResourceOriginalPolicy(maximumOriginalBytes=source.length(),maximumTemporaryBytes=source.length()))
            fails { imported(files,source) };assertEquals(ResourceAssetAvailability.Unavailable,files.selected(ResourceUsage.UserAvatar).single().availability)
            files.discardSelection(store.resourceAssets().single().id);files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun renamedReservationRecoversAfterQuotaReductionAndFrozenUploadMetadataSurvivesDatabaseReopen()=runBlocking {
        val source=source();var store=store();var files=ManagedResourceFiles(context,store,checkpoint={ if(it==ManagedResourceFiles.PublicationCheckpoint.Renamed) throw java.io.IOException("crash after rename") })
        try {
            fails { imported(files,source) };files.close();store.close();store=store();store.setResourceStoragePolicy(ResourceOriginalPolicy(maximumOriginalBytes=1,maximumTemporaryBytes=1));files=ManagedResourceFiles(context,store)
            val asset=files.selected(ResourceUsage.UserAvatar).single();assertEquals(ResourceAssetAvailability.Local,asset.availability)
            val work=store.prepareResourceUpload(id(),asset.id,request(asset));val session=session(work);store.saveResourceUploadSession(work.id,session)
            fails { store.saveResourceUploadSession(work.id,session.copy(media=id())) };fails { store.prepareResourceUpload(id(),asset.id,work.request.copy(operation=id())) }
            files.close();store.close();store=store();files=ManagedResourceFiles(context,store)
            assertEquals(session,store.resourceUploads().single().session);assertEquals(work.request,store.resourceUploads().single().request)
            files.withOriginal(upload=work.id) { assertEquals(source.readText(),it.readText()) }
            val other=SqliteClientStore(context,UserId(id()),device);val otherFiles=ManagedResourceFiles(context,other)
            try { assertTrue(otherFiles.selected(ResourceUsage.UserAvatar).isEmpty());fails { otherFiles.withOriginal(upload=work.id) { } } } finally { otherFiles.close();other.close() }
            store.requestResourceUploadCancellation(work.id);store.confirmResourceUploadCancellation(work.id,session.copy(state=ResourceSessionState.Cancelled));store.releaseResourceUploadSource(work.id);files.cleanup()
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun confirmedReadyCannotRegressAndCancellationLosingToCompletionNeverReactivatesSelection()=runBlocking {
        val source=source();val store=store();val files=ManagedResourceFiles(context,store)
        try {
            val asset=imported(files,source);val work=store.prepareResourceUpload(id(),asset.id,request(asset));val pending=session(work)
            val ready=pending.copy(state=ResourceSessionState.Completed,resourceState=ResourceState.Ready,bindableUntil=2000000000000)
            store.saveResourceUploadSession(work.id,ready);fails { store.saveResourceUploadSession(work.id,pending) };assertEquals(ResourceUploadStage.Ready,store.resourceUploads().single().stage)
            store.releaseResourceUploadSource(work.id);files.cleanup()
            val second=imported(files,source);val next=store.prepareResourceUpload(id(),second.id,request(second));store.requestResourceUploadCancellation(next.id)
            val lost=store.confirmResourceUploadCancellation(next.id,session(next).copy(state=ResourceSessionState.Completed))
            assertTrue(lost.cancellationRequested);assertTrue(lost.terminal);assertFalse(lost.session!!.bindable(System.currentTimeMillis()));assertFalse(store.resourceAssets().first { it.id==second.id }.selectionActive)
            store.releaseResourceUploadSource(next.id);files.cleanup()
        } finally { files.close();store.close();source.delete() }
    }
    @Test fun pendingCapacityKeepsUnknownIdentitiesAndFailedAdmissionDoesNotConsumeSelection()=runBlocking {
        val source=source();val store=store();val files=ManagedResourceFiles(context,store)
        try {
            repeat(32) { val asset=imported(files,source);store.prepareResourceUpload(id(),asset.id,request(asset)) }
            val extra=imported(files,source);val proposal=request(extra);val jobId=id()
            fails { store.prepareResourceUpload(jobId,extra.id,proposal) }
            assertEquals(32,store.resourceUploads().size);assertTrue(store.resourceAssets().first { it.id==extra.id }.selectionActive)
            val first=store.resourceUploads().first();store.requestResourceUploadCancellation(first.id)
            fails { store.prepareResourceUpload(jobId,extra.id,proposal) }
            store.confirmResourceUploadCancellation(first.id,session(first,ResourceSessionState.Cancelled));store.releaseResourceUploadSource(first.id)
            assertEquals(proposal,store.prepareResourceUpload(jobId,extra.id,proposal).request)
            assertEquals(32,store.resourceUploads().count { !it.terminal });assertEquals(1,store.resourceFiles().size)
            for(work in store.resourceUploads().filter { !it.terminal }) {
                store.requestResourceUploadCancellation(work.id);store.confirmResourceUploadCancellation(work.id,session(work,ResourceSessionState.Cancelled));store.releaseResourceUploadSource(work.id)
            }
            files.cleanup();assertTrue(store.resourceFiles().isEmpty())
        } finally { files.close();store.close();source.delete() }
    }
}
