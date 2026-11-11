package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class SendImportStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());var now=1700000000000L
        var store=SqliteClientStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var service=SendIntentService(actor,store) {now}
        fun source()=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(RoomId(id()),MessageId(id()),id()),ResourceUsage.Attachment(room),id()))
        suspend fun local(): SendAttachment {
            val file=File.createTempFile("send-import-",".txt",context.cacheDir)
            try {file.writeText("本地附件");val asset=files.importFile(file,"local.txt","text/plain",ResourceUsage.Attachment(room),1024)
                return SendAttachment(id(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
            } finally {file.delete()}
        }
        suspend fun ready(source: SendImportedAttachment,until: Long=now+100000) {
            val claim=store.claimResourceImport(source.id,id(),now)!!
            store.finishResourceImport(claim,ResourceImportStatus(source.request.locator(actor),source.request.targetMedia,ResourceImportState.Ready,until),now)
        }
        suspend fun ready(source: SendAttachment) {store.saveResourceUploadSession(source.id,ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),source.id,1,
            ResourceSessionState.Completed,ResourceState.Ready,now+200000,now+100000,persistentListOf(),null))}
        fun receipt(command: MessageSendOperation)=MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(command.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint))
            .setResolvedAtMs(now).setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(id()).setRoomSequence(1)).build()
        suspend fun reopen() {files.close();store.close();store=SqliteClientStore(context,actor,device);files=ManagedResourceFiles(context,store);service=SendIntentService(actor,store) {now}}
        suspend fun close() {files.close();store.close()}
    }
    private suspend fun fails(body: suspend ()->Unit) {assertTrue(runCatching {body()}.isFailure)}
    @Test fun mixedDependenciesFreezeInOrderAndUnknownMessageKeepsImportsUntilAccepted()=runBlocking<Unit> {
        val f=Fixture();try {
            val a=f.source();val local=f.local();val b=f.source()
            val prepared=f.service.prepare(f.room,"mixed",persistentListOf(local),serverImports=persistentListOf(a,b),attachmentOrder=persistentListOf(b.id,local.id,a.id))
            f.service.enqueue(prepared);assertEquals(prepared,f.service.enqueue(prepared));assertEquals(2,f.store.resourceImports().size)
            fails {f.store.cancelResourceImport(a.id)};f.ready(local);f.ready(a);f.service.prepareNext();assertTrue(f.store.pending().isEmpty())
            f.ready(b);f.service.prepareNext();val command=f.store.pending().single()
            assertEquals(listOf(b.request.targetMedia,local.id,a.request.targetMedia),command.mediaIdsList)
            f.reopen();f.service.prepareNext();assertEquals(command,f.store.pending().single())
            fails {f.service.discard(prepared.id)};assertEquals(prepared.id,f.service.resumeOrReapply(prepared.id).id)
            assertFalse(f.store.sendIntents().single().canReplace);fails {f.store.cancelResourceImport(b.id)}
            val claim=f.store.claimSend(f.now)!!
            fails {f.store.completeSend(claim,f.receipt(command).toBuilder().setFingerprint(MessageSendOperationFingerprint.getDefaultInstance()).build())}
            assertFalse(f.store.resourceImports().any {it.businessBound})
            f.store.completeSend(claim,f.receipt(command));f.reopen()
            assertTrue(f.store.sendIntents().single().intent.sourcesReleased)
            assertTrue(f.store.resourceImports().all {it.businessBound && !it.cancellationRequested})
            fails {f.store.cancelResourceImport(a.id)};assertTrue(f.store.pending().isEmpty())
        } finally {f.close()}
    }
    @Test fun expiredBindingsReapplyFreshImportsPreservingSourceAndMixedOrder()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();val local=f.local()
            val old=f.service.enqueue(f.service.prepare(f.room,"same body",persistentListOf(local),serverImports=persistentListOf(source),attachmentOrder=persistentListOf(source.id,local.id)))
            f.ready(source,f.now+1);f.ready(local);f.now+=2;f.service.prepareNext()
            assertEquals(SendIntentPhase.Expired,f.store.sendIntents().single().phase);assertTrue(f.store.pending().isEmpty())
            val next=f.service.resumeOrReapply(old.id);assertNotEquals(old.operation,next.operation)
            val replacement=next.serverImports.single();assertNotEquals(source.id,replacement.id);assertNotEquals(source.request.operation,replacement.request.operation)
            assertNotEquals(source.request.targetMedia,replacement.request.targetMedia);assertEquals(source.request.source,replacement.request.source)
            assertEquals(persistentListOf(replacement.id,next.attachments.single().id),next.attachmentOrder)
            assertTrue(f.store.resourceImports().first {it.id==source.id}.cancellationRequested)
            f.reopen();f.ready(replacement);f.ready(next.attachments.single());f.service.prepareNext()
            assertEquals(next.mediaIds,f.store.pending().single().mediaIdsList);assertEquals(2,f.store.sendIntents().size)
        } finally {f.close()}
    }
    @Test fun preparationCancellationFencesLateReadyAndManualResumeRetainsOriginalJob()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();val intent=f.service.enqueue(f.service.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(source)))
            val claim=f.store.claimResourceImport(source.id,id(),f.now)!!
            f.store.failResourceImport(claim,ResourceImportIssue.AuthorizationUnavailable,null,f.now+5000)
            f.service.prepareNext();assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase)
            assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id);assertNull(f.store.claimResourceImport(source.id,id(),f.now))
            f.now+=5000;val running=f.store.claimResourceImport(source.id,id(),f.now)!!
            f.service.prepareNext();assertTrue(f.store.pending().isEmpty());f.service.discard(intent.id)
            f.store.finishResourceImport(running,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Ready,f.now+100000),f.now)
            f.reopen();f.service.prepareNext()
            val late=f.store.resourceImports().single();assertTrue(late.cancellationRequested);assertFalse(late.bindable(f.now));assertFalse(late.businessBound)
            assertEquals(SendIntentPhase.Cancelled,f.store.sendIntents().single().phase);assertTrue(f.store.pending().isEmpty())
        } finally {f.close()}
    }
    @Test fun conflictingConsumerRollsBackNewImportsUploadsAndLocalSourceAdoption()=runBlocking<Unit> {
        val f=Fixture();try {
            val claimed=f.source();f.service.enqueue(f.service.prepare(f.room,"owner",persistentListOf(),serverImports=persistentListOf(claimed)))
            val first=f.source();val local=f.local()
            val next=f.service.prepare(f.room,"conflict",persistentListOf(local),serverImports=persistentListOf(first,claimed))
            fails {f.service.enqueue(next)};f.reopen()
            assertEquals(listOf(claimed.id),f.store.resourceImports().map {it.id});assertTrue(f.store.resourceUploads().isEmpty())
            assertEquals(1,f.store.sendIntents().size);assertEquals(local.asset,f.files.selected(ResourceUsage.Attachment(f.room)).single().id)
            fails {f.store.enqueueSendIntent(next.copy(actor=UserId(id())),f.now)}
            f.store.unavailable(f.room);fails {f.service.enqueue(next)};assertEquals(1,f.store.sendIntents().size)
        } finally {f.close()}
    }
    @Test fun combinedTransferCapacityFailureRollsBackTheWholeSendIntent()=runBlocking<Unit> {
        val f=Fixture();try {
            repeat(31) {val source=f.source();f.store.prepareResourceImport(source.id,source.request,f.now)}
            val first=f.source();val second=f.source()
            fails {f.service.enqueue(f.service.prepare(f.room,"",persistentListOf(),serverImports=persistentListOf(first,second)))}
            assertEquals(31,f.store.resourceImports().size);assertTrue(f.store.sendIntents().isEmpty());f.reopen()
            assertFalse(f.store.resourceImports().any {it.id==first.id || it.id==second.id})
        } finally {f.close()}
    }
    @Test fun importCompletionWakesExistingPreparationObserverWithoutAnotherEnqueue()=runBlocking<Unit> {
        val f=Fixture();val worker=launch {f.service.runPreparation()}
        try {
            val source=f.source();val intent=f.service.enqueue(f.service.prepare(f.room,"import observer",persistentListOf(),serverImports=persistentListOf(source)))
            delay(50);assertTrue(f.store.pending().isEmpty());f.ready(source)
            withTimeout(5000) {while(f.store.pending().none {it.clientMessageId==intent.operation}) delay(25)}
            assertEquals(listOf(source.request.targetMedia),f.store.pending().single().mediaIdsList)
        } finally {worker.cancelAndJoin();f.close()}
    }
    @Test fun pausedCopyingWaitsButAuthoritativeReadyUnblocksParentWithoutNewIdentity()=runBlocking<Unit> {
        val f=Fixture();try {
            val source=f.source();val intent=f.service.enqueue(f.service.prepare(f.room,"paused race",persistentListOf(),serverImports=persistentListOf(source)))
            val first=f.store.claimResourceImport(source.id,id(),f.now)!!;f.store.controlResourceImport(source.id,true)
            f.store.finishResourceImport(first,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Copying),f.now)
            f.service.prepareNext();assertTrue(f.store.resourceImports().single().execution.paused)
            assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase)
            assertFalse(f.service.prepareNext());assertTrue(f.store.pending().isEmpty())
            assertEquals(intent.id,f.service.resumeOrReapply(intent.id).id)
            f.now+=2000;val next=f.store.claimResourceImport(source.id,id(),f.now)!!
            f.store.controlResourceImport(source.id,true);f.service.prepareNext()
            assertEquals(SendIntentPhase.NeedsAttention,f.store.sendIntents().single().phase)
            f.store.finishResourceImport(next,ResourceImportStatus(source.request.locator(f.actor),source.request.targetMedia,ResourceImportState.Ready,f.now+100000),f.now)
            f.reopen();assertFalse(f.store.resourceImports().single().execution.paused);f.service.prepareNext()
            assertEquals(intent.operation,f.store.pending().single().clientMessageId)
            assertEquals(listOf(source.request.targetMedia),f.store.pending().single().mediaIdsList)
        } finally {f.close()}
    }
}
