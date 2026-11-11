package com.xmtx.im.client

import kotlinx.collections.immutable.persistentListOf
import java.util.UUID
import kotlin.test.*

class ResourceOperationDiagnosticsTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun work()=ResourceUploadWork(id(),id(),ResourceUploadRequest(id(),id(),ResourceUsage.UserAvatar,"image/png",1,ResourceChecksum("a".repeat(64))))
    private fun session(work:ResourceUploadWork)=ResourceUploadSession(ResourceUploadLocator(ResourceHome.Account(UserId(id())),id()),work.request.media,1,
        ResourceSessionState.Completed,ResourceState.Ready,100000,100000,persistentListOf(),null)
    @Test fun `only verified resource control facts provide terminal observations`() {
        val legacy=work().copy(stage=ResourceUploadStage.Transferring)
        assertEquals(OperationExecutionState.AwaitingConfirmation,legacy.operationObservation(1000).execution)
        val work=work().copy(execution=ResourceUploadExecution(totalAttempts=3))
        assertEquals(OperationExecutionState.AwaitingConfirmation,work.copy(stage=ResourceUploadStage.Ready).operationObservation(1000).execution)
        val ready=work.copy(stage=ResourceUploadStage.Ready,session=session(work))
        assertEquals(OperationExecutionState.Committed,ready.operationObservation(1000).execution)
        val processing=work.copy(stage=ResourceUploadStage.Processing,session=session(work).copy(resourceState=ResourceState.Processing,bindableUntil=null))
        assertEquals(OperationExecutionState.Processing,processing.operationObservation(1000).execution)
        val closed=work.copy(stage=ResourceUploadStage.Cancelled,session=session(work).copy(state=ResourceSessionState.Cancelled,resourceState=ResourceState.Pending,bindableUntil=null))
        assertEquals(OperationExecutionState.Closed,closed.operationObservation(1000).execution)
    }
    @Test fun `background handoff and user pause suspend local dispatch without proving completion`() {
        val work=work().copy(execution=ResourceUploadExecution(totalAttempts=2,backgroundPending=true))
        val observed=work.operationObservation(1000)
        assertEquals(OperationExecutionState.AwaitingConfirmation,observed.execution);assertEquals(OperationSchedulingState.Suspended,observed.scheduling)
        assertEquals(OperationSchedulingState.Suspended,work.copy(execution=work.execution.copy(backgroundPending=false,userPaused=true)).operationObservation(1000).scheduling)
        assertEquals(OperationSchedulingState.Claimed,work.copy(execution=work.execution.copy(backgroundPending=false,owner=id(),token=id())).operationObservation(1000).scheduling)
    }
    @Test fun `avatar local cancellation closure and active claim remain distinct`() {
        val actor=UserId(id());val device=DeviceId(id());val command=GroupAvatarCommand(id(),RoomId(id()),0,GroupAvatarMutation.Remove)
        val work=GroupAvatarIntent(actor,device,command,1000)
        assertEquals(OperationExecutionState.CancelledLocally,work.copy(stage=GroupAvatarStage.Cancelled).operationObservation(1000).execution)
        val submitted=work.copy(stage=GroupAvatarStage.Submitted,submissionStarted=true,attempts=1,claim=id(),claimUntil=2000)
        assertEquals(OperationSchedulingState.Claimed,submitted.operationObservation(1000).scheduling)
        val closed=submitted.copy(stage=GroupAvatarStage.Closed,claim=null,claimUntil=null,
            proof=GroupAvatarClosureProof(actor,device,GroupAvatarRecoveryRequest(command,GroupAvatarRecoveryAction.CloseIfAbsent)))
        assertEquals(OperationExecutionState.Closed,closed.operationObservation(1000).execution)
        assertEquals(OperationSchedulingState.Finished,closed.operationObservation(1000).scheduling)
    }
}
