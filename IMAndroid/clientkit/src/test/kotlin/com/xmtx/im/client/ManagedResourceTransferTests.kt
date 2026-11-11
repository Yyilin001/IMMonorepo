package com.xmtx.im.client

import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ManagedResourceTransferTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id());private val actor=UserId(id())
    private fun upload()=ResourceUploadWork(id(),id(),ResourceUploadRequest(id(),id(),ResourceUsage.Attachment(room),"text/plain",10,ResourceChecksum("a".repeat(64))))
    private fun imported()=ResourceImportWork(id(),ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),ResourceUsage.UserAvatar,id()),100)
    @Test fun pauseAndCancellationAreDifferentCapabilitiesAndBusyWorkCannotResume() {
        val work=upload();val paused=work.copy(execution=ResourceUploadExecution(userPaused=true,attention=true))
        val value=ResourceTransferProjection.upload(paused,100,false,200)
        assertEquals(ResourceTransferGroup.Attention,value.group);assertEquals(ResourceTransferPhase.Paused,value.phase)
        assertEquals(persistentSetOf(ResourceTransferAction.Resume,ResourceTransferAction.CancelUnbound),value.actions)
        val busy=ResourceTransferProjection.upload(paused.copy(execution=paused.execution.copy(owner=id(),token=id())),100,true,200)
        assertEquals(ResourceTransferPhase.Pausing,busy.phase);assertTrue(busy.actions.isEmpty())
        val cancellation=ResourceTransferProjection.upload(work.copy(cancellationRequested=true,execution=ResourceUploadExecution(attention=true)),100,false,200)
        assertEquals(ManagedResourceTransferFailure.CancellationUnconfirmed,cancellation.failure)
        assertEquals(persistentSetOf(ResourceTransferAction.RetryCancellation),cancellation.actions)
        val owned=ResourceTransferProjection.upload(work,100,true,200);assertEquals(persistentSetOf(ResourceTransferAction.Pause),owned.actions)
    }
    @Test fun automaticRetryDoesNotPretendTheNextStatusRequestIsAlreadyRunning() {
        val work=upload().copy(stage=ResourceUploadStage.Paused,execution=ResourceUploadExecution(next=ResourceUploadAction.Status,retryAt=500,serverRetryAt=600))
        val waiting=ResourceTransferProjection.upload(work,100,false,200)
        assertEquals(ResourceTransferPhase.WaitingRetry,waiting.phase);assertEquals(600L,waiting.retryAt)
        assertEquals(ResourceTransferPhase.Queued,ResourceTransferProjection.upload(work,100,false,601).phase)
        val busy=work.copy(execution=work.execution.copy(owner=id(),token=id()))
        assertEquals(ResourceTransferPhase.Confirming,ResourceTransferProjection.upload(busy,100,false,601).phase)
    }
    @Test fun confirmedProgressNeverIncludesAttemptBytesAndOverflowIsRejected() {
        val work=upload();val session=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Room(room),id()),work.request.media,1,ResourceSessionState.Uploading,ResourceState.Pending,9999,null,persistentListOf(ResourceUploadPart(1,3)),null)
        assertNull(ResourceTransferProjection.upload(work,1,false,200).confirmedBytes)
        assertEquals(3L,ResourceTransferProjection.upload(work.copy(session=session),1,false,200).confirmedBytes)
        val overflowing=session.copy(parts=persistentListOf(ResourceUploadPart(1,Long.MAX_VALUE),ResourceUploadPart(2,2)))
        assertTrue(runCatching {ResourceTransferProjection.upload(work.copy(session=overflowing),1,false,200)}.isFailure)
        val complete=session.copy(state=ResourceSessionState.Completed,resourceState=ResourceState.Ready,bindableUntil=9999)
        assertEquals(10L,ResourceTransferProjection.upload(work.copy(session=complete,stage=ResourceUploadStage.Ready),1,false,200).confirmedBytes)
    }
    @Test fun readyImportWhileCancellationIsUnconfirmedDoesNotBecomeCompleted() {
        val work=imported();val ready=ResourceImportStatus(work.request.locator(actor),work.request.targetMedia,ResourceImportState.Ready,9999)
        val pending=work.copy(status=ready,cancellationRequested=true)
        assertEquals(ResourceTransferPhase.Cancelling,ResourceTransferProjection.serverImport(pending,false,200).phase)
        val stalled=ResourceTransferProjection.serverImport(pending.copy(execution=ResourceImportExecution(attention=true)),false,200)
        assertEquals(persistentSetOf(ResourceTransferAction.RetryCancellation),stalled.actions)
        val completed=ResourceTransferProjection.serverImport(pending.copy(cancellationResolved=true),false,200)
        assertEquals(ResourceTransferGroup.Finished,completed.group);assertTrue(completed.actions.isEmpty());assertNull(completed.totalBytes)
        assertFalse(ResourceTransferAction.CancelUnbound in ResourceTransferProjection.serverImport(work.copy(status=ready,businessBound=true,retained=false),false,200).actions)
    }
    @Test fun revokedDownloadHidesNameAndNavigationButRetainsCancellation() {
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"private.txt","text/plain",10,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
        val work=ResourceDownloadWork(id(),descriptor,MediaMessageLocation(room,MessageId(id())),100,requested=false,issue=ResourceDownloadIssue.Unavailable)
        val revoked=ResourceTransferProjection.download(ResourceDownloadSnapshot(work,false),200)
        assertNull(revoked.displayName);assertNull(revoked.resource);assertEquals(persistentSetOf(ResourceTransferAction.Cancel),revoked.actions)
        assertEquals(ResourceTransferGroup.Attention,revoked.group)
        val allowed=ResourceTransferProjection.download(ResourceDownloadSnapshot(work,true),200)
        assertTrue(ResourceTransferAction.Retry in allowed.actions)
        val paused=ResourceTransferProjection.download(ResourceDownloadSnapshot(work.copy(control=ResourceDownloadControl.Pause),true),200)
        assertFalse(ResourceTransferAction.Retry in paused.actions);assertTrue(ResourceTransferAction.Resume in paused.actions)
    }
    @Test fun typedIdsCursorBoundsAndPersistentSnapshots() {
        val common=id();assertNotEquals(ResourceTransferId(ResourceTransferKind.Upload,common),ResourceTransferId(ResourceTransferKind.Download,common))
        assertTrue(runCatching {ResourceTransferQuery(limit=101)}.isFailure);assertTrue(runCatching {ResourceTransferQuery(limit=0)}.isFailure)
        val row=ResourceTransferProjection.upload(upload(),100,false,200)
        val builder=persistentListOf(row).builder();val page=ResourceTransferPage(builder.build());builder.clear();assertEquals(1,page.entries.size)
        assertTrue(runCatching {ResourceTransferPage(persistentListOf(row),row.cursor.copy(createdAt=101))}.isFailure)
        val results=persistentListOf(ResourceTransferBatchItem(row.id,ResourceTransferBatchOutcome.Failed))
        assertEquals(persistentListOf(row.id),ResourceTransferBatchResult(ResourceTransferAction.Retry,results).failedIds)
        assertTrue(runCatching {ResourceTransferBatchResult(ResourceTransferAction.Resume,results)}.isFailure)
    }
}
