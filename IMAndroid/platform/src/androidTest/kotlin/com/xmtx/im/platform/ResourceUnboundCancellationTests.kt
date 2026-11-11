package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class ResourceUnboundCancellationTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val now=System.currentTimeMillis()
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        suspend fun upload():ResourceUploadWork {
            val file=File.createTempFile("unbound-",".txt",context.cacheDir)
            try {file.writeText("reviewed source");val asset=files.importFile(file,"原件.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
            } finally {file.delete()}
        }
        suspend fun imported(usage:ResourceUsage=ResourceUsage.Attachment(room))=store.prepareResourceImport(id(),ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),usage,id()),now)
        fun key(work:ResourceUploadWork)=ResourceTransferId(ResourceTransferKind.Upload,work.id)
        fun key(work:ResourceImportWork)=ResourceTransferId(ResourceTransferKind.ServerImport,work.id)
        fun sql(body:(SQLiteDatabase)->Unit) {SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-${store.resourceScope}.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)}
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun close() {files.close();store.close()}
    }
    @Test fun reviewedUploadAndImportCancellationPersistOriginalIdentityAndServerCooldown()=runBlocking {
        val f=Fixture();try {
            val upload=f.upload();val imported=f.imported();val floor=f.now+60000
            f.store.failResourceUpload(f.store.claimResourceUpload(upload.id,id(),f.now)!!,ResourceUploadError.Transport,null,floor)
            f.store.failResourceImport(f.store.claimResourceImport(imported.id,id(),f.now)!!,ResourceImportIssue.Transport,null,floor)
            for(key in listOf(f.key(upload),f.key(imported))) {
                val plan=f.store.planUnboundResourceCancellation(key)
                assertTrue(runCatching {f.store.controlResourceTransfer(key,ResourceTransferAction.CancelUnbound)}.exceptionOrNull() is ResourceTransferActionUnavailable)
                f.store.cancelUnboundResource(plan)
                assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            }
            f.reopen();val u=f.store.resourceUploads().single();val i=f.store.resourceImports().single()
            assertEquals(upload.request,u.request);assertEquals(upload.asset,u.asset);assertEquals(imported.request,i.request)
            assertTrue(u.cancellationRequested);assertTrue(i.cancellationRequested);assertFalse(u.sourceReleased);assertTrue(i.retained)
            assertEquals(floor,u.execution.retryAt);assertEquals(floor,i.execution.retryAt);assertEquals(0,u.execution.attempts);assertEquals(0,i.execution.attempts)
            assertNull(f.store.claimResourceUpload(u.id,id(),f.now));assertNull(f.store.claimResourceImport(i.id,id(),f.now))
            f.files.withOriginal(upload=u.id) {assertEquals("reviewed source",it.readText())};assertTrue(f.store.pending().isEmpty())
        } finally {f.close()}
    }
    @Test fun newMessageOwnerInvalidatesReviewedImportWithoutCancellingTheParent()=runBlocking {
        val f=Fixture();try {
            val work=f.imported();val plan=f.store.planUnboundResourceCancellation(f.key(work));val sending=SendIntentService(f.actor,f.store) {f.now}
            sending.enqueue(sending.prepare(f.room,"new owner",persistentListOf(),serverImports=persistentListOf(SendImportedAttachment(work.id,work.request))))
            assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertFalse(f.store.resourceImports().single().cancellationRequested);assertEquals(SendIntentPhase.Preparing,f.store.sendIntents().single().phase)
        } finally {f.close()}
    }
    @Test fun readyAfterReviewRejectsBothKindsWithoutDiscardingTheirLocalSources()=runBlocking {
        val f=Fixture();try {
            val upload=f.upload();val imported=f.imported();val plans=listOf(f.store.planUnboundResourceCancellation(f.key(upload)),f.store.planUnboundResourceCancellation(f.key(imported)))
            f.store.saveResourceUploadSession(upload.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(f.room),id()),upload.request.media,1,ResourceSessionState.Completed,ResourceState.Ready,f.now+120000,f.now+120000,persistentListOf(),null))
            f.store.finishResourceImport(f.store.claimResourceImport(imported.id,id(),f.now)!!,ResourceImportStatus(imported.request.locator(f.actor),imported.request.targetMedia,ResourceImportState.Ready,f.now+120000),f.now)
            for(plan in plans) {
                assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
                assertTrue(runCatching {f.store.planUnboundResourceCancellation(plan.transfer)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            }
            assertFalse(f.store.resourceUploads().single().cancellationRequested);assertFalse(f.store.resourceUploads().single().sourceReleased)
            assertFalse(f.store.resourceImports().single().cancellationRequested);assertTrue(f.store.resourceImports().single().retained)
        } finally {f.close()}
    }
    @Test fun frozenRequestAndAssetAreRecheckedEvenWhenTheTaskKeyIsUnchanged()=runBlocking {
        val f=Fixture();try {
            val upload=f.upload();val other=f.upload();val imported=f.imported()
            val up=f.store.planUnboundResourceCancellation(f.key(upload));val ip=f.store.planUnboundResourceCancellation(f.key(imported))
            f.sql {it.execSQL("UPDATE resource_uploads SET asset=? WHERE id=?",arrayOf(other.asset,upload.id))
                it.execSQL("UPDATE resource_imports SET request=? WHERE id=?",arrayOf(imported.request.copy(source=ResourceImportSource.Message(f.room,MessageId(id()),id())).payload().toString(),imported.id))}
            for(plan in listOf(up,ip)) assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertTrue(f.store.resourceUploads().none {it.cancellationRequested});assertFalse(f.store.resourceImports().single().cancellationRequested)
        } finally {f.close()}
    }
    @Test fun previewsAreSingleUseInstanceBoundAndBoundedWithoutBlockingFurtherReview()=runBlocking {
        val f=Fixture();try {
            val work=f.imported();val key=f.key(work);val plan=f.store.planUnboundResourceCancellation(key)
            SqliteClientStore(context,f.actor,f.device).use {other->assertTrue(runCatching {other.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)}
            assertTrue(runCatching {f.store.cancelUnboundResource(plan.copy(transfer=key.copy(value=id())))}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            val old=f.store.planUnboundResourceCancellation(key);repeat(16) {f.store.planUnboundResourceCancellation(key)}
            assertTrue(runCatching {f.store.cancelUnboundResource(old)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            val reopened=f.store.planUnboundResourceCancellation(key);f.reopen()
            assertTrue(runCatching {f.store.cancelUnboundResource(reopened)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            f.store.cancelUnboundResource(f.store.planUnboundResourceCancellation(key));assertTrue(f.store.resourceImports().single().cancellationRequested)
        } finally {f.close()}
    }
    @Test fun failedWriterRollsBackCancellationAndRequiresFreshReview()=runBlocking {
        val f=Fixture();try {
            val work=f.upload();val plan=f.store.planUnboundResourceCancellation(f.key(work));val before=f.store.resourceUploads().single()
            f.sql {it.execSQL("CREATE TRIGGER reject_unbound BEFORE UPDATE OF execution ON resource_uploads BEGIN SELECT RAISE(ABORT,'test failure'); END")}
            assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.isFailure);assertEquals(before,f.store.resourceUploads().single())
            f.sql {it.execSQL("DROP TRIGGER reject_unbound")}
            assertTrue(runCatching {f.store.cancelUnboundResource(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            f.store.cancelUnboundResource(f.store.planUnboundResourceCancellation(f.key(work)));assertTrue(f.store.resourceUploads().single().cancellationRequested)
        } finally {f.close()}
    }
    @Test fun standaloneAvatarImportsAndDownloadsCannotUseAttachmentCancellation()=runBlocking {
        val f=Fixture();try {
            for(usage in listOf(ResourceUsage.UserAvatar,ResourceUsage.GroupAvatar(f.room))) {
                val work=f.imported(usage);val key=f.key(work)
                assertTrue(runCatching {f.store.planUnboundResourceCancellation(key)}.exceptionOrNull() is ResourceTransferActionUnavailable)
                assertFalse(ResourceTransferAction.CancelUnbound in f.store.resourceTransfers().entries.first {it.id==key}.actions)
            }
            assertTrue(runCatching {f.store.planUnboundResourceCancellation(ResourceTransferId(ResourceTransferKind.Download,id()))}.exceptionOrNull() is ResourceTransferActionUnavailable)
        } finally {f.close()}
    }
}
