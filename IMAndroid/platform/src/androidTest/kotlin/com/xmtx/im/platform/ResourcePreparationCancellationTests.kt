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

class ResourcePreparationCancellationTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val now=System.currentTimeMillis()
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        val sending get()=SendIntentService(actor,store) {now}
        fun imported()=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),ResourceUsage.Attachment(room),id()))
        suspend fun local():SendAttachment {
            val file=File.createTempFile("cancel-prepare-",".txt",context.cacheDir)
            try {file.writeText("original");val asset=files.importFile(file,"原件.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return SendAttachment(id(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
            } finally {file.delete()}
        }
        fun key(source:SendAttachment)=ResourceTransferId(ResourceTransferKind.Upload,source.id)
        fun key(source:SendImportedAttachment)=ResourceTransferId(ResourceTransferKind.ServerImport,source.id)
        suspend fun ready(source:SendAttachment) {store.saveResourceUploadSession(source.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),source.id,1,ResourceSessionState.Completed,ResourceState.Ready,now+120000,now+120000,persistentListOf(),null))}
        suspend fun ready(source:SendImportedAttachment) {val claim=store.claimResourceImport(source.id,id(),now)!!;store.finishResourceImport(claim,status(source),now)}
        fun status(source:SendImportedAttachment)=ResourceImportStatus(source.request.locator(actor),source.request.targetMedia,ResourceImportState.Ready,now+120000)
        fun sql(body:(SQLiteDatabase)->Unit) {SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-${store.resourceScope}.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)}
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store)}
        suspend fun close() {files.close();store.close()}
    }
    @Test fun mixedParentWithdrawsAllUnfinishedDependenciesAndPreservesReadySiblingAcrossReopen()=runBlocking {
        val f=Fixture();try {
            val upload=f.local();val pending=f.imported();val ready=f.imported()
            val intent=f.sending.enqueue(f.sending.prepare(f.room,"混合附件",persistentListOf(upload),serverImports=persistentListOf(pending,ready)))
            f.ready(ready)
            val row=f.store.resourceTransfers().entries.first {it.id==f.key(upload)}
            assertEquals(1,row.cancellableMessageCount);assertTrue(ResourceTransferAction.CancelPreparation in row.actions);assertFalse(ResourceTransferAction.CancelUnbound in row.actions)
            assertTrue(runCatching {f.store.controlResourceTransfer(row.id,ResourceTransferAction.CancelPreparation)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            val plan=f.store.planResourcePreparationCancellation(row.id);assertEquals(1,plan.messageCount)
            val result=f.store.cancelResourcePreparation(plan);assertEquals(ResourcePreparationCancellationResult(1,1,1),result)
            assertTrue(runCatching {f.store.cancelResourcePreparation(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertEquals(SendIntentPhase.Cancelled,f.store.sendIntents().single().phase);assertTrue(f.store.sendIntents().single().intent.sourcesReleased)
            f.reopen();repeat(2) {f.sending.prepareNext()}
            assertTrue(f.store.pending().isEmpty());assertTrue(f.store.resourceUploads().single().cancellationRequested)
            val jobs=f.store.resourceImports();assertTrue(jobs.first {it.id==pending.id}.cancellationRequested)
            assertFalse(jobs.first {it.id==ready.id}.cancellationRequested);assertEquals(ResourceImportState.Ready,jobs.first {it.id==ready.id}.status!!.state)
            assertEquals(intent.operation,f.store.sendIntents().single().intent.operation)
            assertNull(f.store.resourceTransfers().entries.first {it.id==f.key(upload)}.cancellableMessageCount)
        } finally {f.close()}
    }
    @Test fun cancellationDoesNotTouchAnotherMessageEvenWhenOriginalBytesAreShared()=runBlocking {
        val f=Fixture();try {
            val first=f.local();val other=f.local();val imported=f.imported()
            val cancelled=f.sending.enqueue(f.room,"取消这一条",persistentListOf(first))
            val preserved=f.sending.enqueue(f.sending.prepare(f.room,"保留另一条",persistentListOf(other),serverImports=persistentListOf(imported)))
            assertEquals(1,f.store.cancelResourcePreparation(f.store.planResourcePreparationCancellation(f.key(first))).cancelledMessages)
            f.reopen();f.sending.prepareNext()
            val parents=f.store.sendIntents();assertEquals(SendIntentPhase.Cancelled,parents.first {it.intent.id==cancelled.id}.phase)
            assertEquals(SendIntentPhase.Preparing,parents.first {it.intent.id==preserved.id}.phase)
            assertFalse(f.store.resourceUploads().first {it.id==other.id}.cancellationRequested)
            assertFalse(f.store.resourceImports().single().cancellationRequested)
            f.files.withOriginal(upload=other.id) {assertEquals("original",it.readText())}
        } finally {f.close()}
    }
    @Test fun outboxHandoffAfterPreviewRejectsTheWholeCancellationWithoutTouchingReadyResources()=runBlocking {
        val f=Fixture();try {
            val source=f.local();val intent=f.sending.enqueue(f.room,"已经交接",persistentListOf(source));val plan=f.store.planResourcePreparationCancellation(f.key(source))
            f.ready(source);f.sending.prepareNext();assertEquals(intent.operation,f.store.pending().single().clientMessageId)
            assertTrue(runCatching {f.store.cancelResourcePreparation(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            assertEquals(SendPreparation.HandedOff,f.store.sendIntents().single().intent.preparation)
            assertFalse(f.store.resourceUploads().single().cancellationRequested);assertFalse(f.store.sendIntents().single().intent.sourcesReleased)
            assertTrue(runCatching {f.store.planResourcePreparationCancellation(f.key(source))}.isFailure)
        } finally {f.close()}
    }
    @Test fun readyBetweenPreviewAndCommitStillAllowsWithdrawingTheUnsubmittedParent()=runBlocking {
        val f=Fixture();try {
            val source=f.imported();f.sending.enqueue(f.sending.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(source)))
            val plan=f.store.planResourcePreparationCancellation(f.key(source));f.ready(source)
            assertTrue(runCatching {f.store.planResourcePreparationCancellation(f.key(source))}.isFailure)
            assertEquals(ResourcePreparationCancellationResult(1,0,0),f.store.cancelResourcePreparation(plan))
            f.reopen();f.sending.prepareNext();val job=f.store.resourceImports().single()
            assertFalse(job.cancellationRequested);assertEquals(ResourceImportState.Ready,job.status!!.state);assertTrue(f.store.pending().isEmpty())
        } finally {f.close()}
    }
    @Test fun siblingReleaseFailureRollsBackEarlierParentAndOriginalChanges()=runBlocking {
        val f=Fixture();try {
            val upload=f.local();val source=f.imported();val intent=f.sending.enqueue(f.sending.prepare(f.room,"原子撤销",persistentListOf(upload),serverImports=persistentListOf(source)))
            val plan=f.store.planResourcePreparationCancellation(f.key(upload));val consumer=SendImportConsumer(intent.id,source.id)
            f.sql {it.execSQL("DELETE FROM resource_import_consumers WHERE consumer=?",arrayOf(consumer.key))}
            assertTrue(runCatching {f.store.cancelResourcePreparation(plan)}.isFailure)
            assertEquals(SendPreparation.Preparing,f.store.sendIntents().single().intent.preparation);assertFalse(f.store.resourceUploads().single().cancellationRequested)
            f.sql {db->
                db.rawQuery("SELECT 1 FROM resource_source_claims WHERE consumer=?",arrayOf(SendOriginalConsumer(intent.id,upload.asset).key)).use {assertTrue(it.moveToFirst())}
                db.rawQuery("SELECT cancel_unfinished_only FROM send_intents WHERE id=?",arrayOf(intent.id)).use {it.moveToFirst();assertEquals(0,it.getInt(0))}
                db.execSQL("INSERT INTO resource_import_consumers VALUES(?,?)",arrayOf(consumer.key,source.id))
            }
            assertEquals(1,f.store.cancelResourcePreparation(f.store.planResourcePreparationCancellation(f.key(upload))).cancelledMessages)
        } finally {f.close()}
    }
    @Test fun missingOriginalDoesNotPreventCancellingItsUnsubmittedMessage()=runBlocking {
        val f=Fixture();try {
            val source=f.local();f.sending.enqueue(f.room,"原件丢失",persistentListOf(source));f.store.markResourceAssetUnavailable(source.asset);f.sending.prepareNext()
            assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase)
            val plan=f.store.planResourcePreparationCancellation(f.key(source));assertEquals(1,f.store.cancelResourcePreparation(plan).requestedUploadCancellations)
        } finally {f.close()}
    }
    @Test fun plansAreBoundToTheirExactStoreInstanceScopeAndContentsAndEvictionDoesNotBlockNewPreviews()=runBlocking {
        val f=Fixture();try {
            val source=f.imported();f.sending.enqueue(f.sending.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(source)))
            val plan=f.store.planResourcePreparationCancellation(f.key(source))
            SqliteClientStore(context,f.actor,f.device).use {other->assertTrue(runCatching {other.cancelResourcePreparation(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)}
            assertTrue(runCatching {f.store.cancelResourcePreparation(plan.copy(messageCount=2))}.exceptionOrNull() is ResourceTransferActionUnavailable)
            val evicted=f.store.planResourcePreparationCancellation(f.key(source));var latest=evicted
            repeat(16) {latest=f.store.planResourcePreparationCancellation(f.key(source))}
            assertTrue(runCatching {f.store.cancelResourcePreparation(evicted)}.isFailure)
            f.reopen();assertTrue(runCatching {f.store.cancelResourcePreparation(latest)}.isFailure)
            assertEquals(1,f.store.cancelResourcePreparation(f.store.planResourcePreparationCancellation(f.key(source))).cancelledMessages)
        } finally {f.close()}
    }
    @Test fun cancellationFencesLateImportReadyWithoutCreatingAnotherTargetOrOutboxMessage()=runBlocking {
        val f=Fixture();try {
            val source=f.imported();f.sending.enqueue(f.sending.prepare(f.room,"晚返回",persistentListOf(),serverImports=persistentListOf(source)))
            val claim=f.store.claimResourceImport(source.id,id(),f.now)!!
            val plan=f.store.planResourcePreparationCancellation(f.key(source));f.store.cancelResourcePreparation(plan)
            f.store.finishResourceImport(claim,f.status(source),f.now)
            val late=f.store.resourceImports().single();assertTrue(late.cancellationRequested);assertFalse(late.cancellationResolved);assertFalse(late.bindable(f.now))
            f.reopen();val control=object:ResourceImportControl {
                override suspend fun create(request:ResourceImportRequest):ResourceImportStatus=error("must not create another import")
                override suspend fun status(locator:ResourceImportLocator):ResourceImportStatus=f.status(source)
                override suspend fun cancel(locator:ResourceImportLocator):ResourceImportStatus {assertEquals(source.request.locator(f.actor),locator);return f.status(source)}
            }
            ResourceImportService(f.actor,f.store,control) {f.now+10000}.recoverOnce();f.sending.prepareNext()
            val done=f.store.resourceImports().single();assertEquals(source.request,done.request);assertTrue(done.cancellationResolved);assertTrue(f.store.pending().isEmpty())
        } finally {f.close()}
    }
    @Test fun changedParentScopeAndStandaloneOrAvatarTasksCannotUsePreparationCancellation()=runBlocking {
        val f=Fixture();try {
            val source=f.imported();val intent=f.sending.enqueue(f.sending.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(source)))
            val plan=f.store.planResourcePreparationCancellation(f.key(source));f.sending.discard(intent.id)
            assertTrue(runCatching {f.store.cancelResourcePreparation(plan)}.exceptionOrNull() is ResourceTransferActionUnavailable)
            val standalone=f.imported();f.store.prepareResourceImport(standalone.id,standalone.request,f.now)
            assertTrue(runCatching {f.store.planResourcePreparationCancellation(f.key(standalone))}.isFailure)
            val avatar=f.store.prepareResourceImport(id(),standalone.request.copy(operation=id(),targetMedia=id(),targetUsage=ResourceUsage.UserAvatar),f.now)
            assertTrue(runCatching {f.store.planResourcePreparationCancellation(ResourceTransferId(ResourceTransferKind.ServerImport,avatar.id))}.isFailure)
            assertTrue(runCatching {f.store.planResourcePreparationCancellation(ResourceTransferId(ResourceTransferKind.Download,id()))}.isFailure)
        } finally {f.close()}
    }
    @Test fun legacyDiscardStillCancelsUnusedReadyImportAndNewColumnDefaultsToLegacyPolicy()=runBlocking {
        val f=Fixture();try {
            val source=f.imported();val intent=f.sending.enqueue(f.sending.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(source)))
            f.files.close();f.store.close()
            f.sql {db->db.beginTransaction();try {
                db.execSQL("ALTER TABLE send_intents RENAME TO old_send_intents")
                db.execSQL("CREATE TABLE send_intents(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,payload TEXT NOT NULL)")
                db.execSQL("INSERT INTO send_intents SELECT id,operation,payload FROM old_send_intents")
                db.execSQL("DROP TABLE old_send_intents");db.setTransactionSuccessful()
            } finally {db.endTransaction()}}
            f.store=SqliteClientStore(context,f.actor,f.device);f.files=ManagedResourceFiles(context,f.store)
            f.ready(source);f.sending.discard(intent.id);assertTrue(f.store.resourceImports().single().cancellationRequested)
            f.sql {db->db.rawQuery("SELECT cancel_unfinished_only FROM send_intents WHERE id=?",arrayOf(intent.id)).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
        } finally {f.close()}
    }
}
