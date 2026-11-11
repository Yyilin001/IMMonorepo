package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceUnboundCancellationUiTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun row()=ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.Upload,id()),1,"原件.txt",ResourceUsage.UserAvatar,null,ResourceTransferGroup.Active,ResourceTransferPhase.Queued,actions=persistentSetOf(ResourceTransferAction.CancelUnbound))
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun previewFreezesControlsAndConfirmPassesOnlyTheReviewedPlanOnce()=runBlocking<Unit> {
        val row=row();val plan=ResourceUnboundCancellationPlan(id(),row.id);val gate=CompletableDeferred<Unit>();var previews=0;var commits=0
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->error("review required")},{_,_->error("no batch")},{},
            previewUnbound={previews++;gate.await();plan},cancelUnbound={assertEquals(plan,it);commits++})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelUnbound);owner.act(row.id,ResourceTransferAction.CancelUnbound)
            until {previews==1};assertTrue(owner.state.working);assertNull(owner.state.confirmation);owner.confirm();assertEquals(0,commits)
            gate.complete(Unit);until {owner.state.confirmation!=null && !owner.state.working};assertEquals(plan,owner.state.confirmation!!.unbound)
            owner.confirm();owner.confirm();until {commits==1 && !owner.state.working};assertTrue(owner.state.feedback!!.contains("等待服务端确认"))
        } finally {gate.complete(Unit);owner.close()}
    }
    @Test fun readyOrNewOwnerInvalidatesTheDisplayedUnboundConfirmation()=runBlocking<Unit> {
        val row=row();val changes=MutableStateFlow(0L);var rows=persistentListOf(row);var commits=0
        val owner=ResourceTransfersController(this,changes,{ResourceTransferPage(rows)},{_,_->error("review required")},{_,_->error("no batch")},{},
            previewUnbound={ResourceUnboundCancellationPlan(id(),it)},cancelUnbound={commits++})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelUnbound);until {owner.state.confirmation!=null && !owner.state.working}
            rows=persistentListOf(row.copy(actions=persistentSetOf(),hasBusinessOwners=true));changes.value++;until {owner.state.confirmation==null}
            owner.confirm();assertEquals(0,commits)
            rows=persistentListOf(row);changes.value++;until {owner.state.page.entries.single().actions.isNotEmpty()}
            owner.act(row.id,ResourceTransferAction.CancelUnbound);until {owner.state.confirmation!=null && !owner.state.working}
            rows=persistentListOf();changes.value++;until {owner.state.confirmation==null};owner.confirm();assertEquals(0,commits)
        } finally {owner.close()}
    }
    @Test fun backgroundAndMismatchedPreviewsCannotExposeAnActionAndRejectedCommitNeedsNewReview()=runBlocking<Unit> {
        val row=row();val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();var attempt=0;var commits=0
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->error("review required")},{_,_->error("no batch")},{},
            previewUnbound={attempt++;if(attempt==1) {entered.complete(Unit);withContext(NonCancellable) {gate.await()}};ResourceUnboundCancellationPlan(id(),if(attempt==2) row.id.copy(value=id()) else row.id)},
            cancelUnbound={commits++;throw ResourceTransferActionUnavailable()})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelUnbound);entered.await();owner.foreground(false);gate.complete(Unit);yield()
            assertNull(owner.state.confirmation);owner.confirm();assertEquals(0,commits)
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelUnbound);until {!owner.state.working};assertNull(owner.state.confirmation);assertNotNull(owner.state.feedback)
            owner.act(row.id,ResourceTransferAction.CancelUnbound);until {owner.state.confirmation!=null && !owner.state.working};owner.confirm();until {!owner.state.working}
            assertEquals(1,commits);assertNull(owner.state.confirmation);assertFalse(owner.state.feedback!!.startsWith("已请求取消"));owner.confirm();assertEquals(1,commits)
        } finally {gate.complete(Unit);owner.close()}
    }
}
