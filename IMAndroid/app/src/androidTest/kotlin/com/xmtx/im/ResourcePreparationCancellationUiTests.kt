package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ResourcePreparationCancellationUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun row()=ManagedResourceTransfer(ResourceTransferId(ResourceTransferKind.Upload,id()),1,"附件.txt",ResourceUsage.Attachment(RoomId(id())),null,ResourceTransferGroup.Active,ResourceTransferPhase.Queued,
        actions=persistentSetOf(ResourceTransferAction.CancelPreparation),hasBusinessOwners=true,cancellableMessageCount=1)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun previewFreezesControlsAndReadyRowsLeavingThePageDoNotReplaceTheReviewedScope()=runBlocking<Unit> {
        val row=row();val finish=CompletableDeferred<Unit>();val changes=MutableStateFlow(0L);val plan=ResourcePreparationCancellationPlan(id(),row.id,1)
        var entries=persistentListOf(row);var previews=0;var commits=0
        val owner=ResourceTransfersController(this,changes,{ResourceTransferPage(entries)},{_,_->error("must use reviewed plan")},{_,_->error("no batch")},{},
            previewPreparation={previews++;finish.await();plan},cancelPreparation={assertEquals(plan,it);commits++;ResourcePreparationCancellationResult(1,0,0)})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelPreparation)
            owner.act(row.id,ResourceTransferAction.CancelPreparation);owner.query(ResourceTransferGroup.Finished);until {previews==1};assertTrue(owner.state.working);assertNull(owner.state.confirmation)
            entries=persistentListOf();finish.complete(Unit);until {owner.state.confirmation!=null && !owner.state.working}
            assertEquals(ResourceTransferGroup.Active,owner.state.group);assertEquals(plan,owner.state.confirmation!!.preparation);assertTrue(owner.state.page.entries.isEmpty())
            owner.confirm();owner.confirm();until {commits==1 && !owner.state.working};assertNull(owner.state.confirmation);assertTrue(owner.state.feedback!!.contains("已取消 1 条待发送消息"))
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun backgroundDropsLatePreviewAndCannotCommitItsDetachedPlan()=runBlocking<Unit> {
        val row=row();val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var commits=0
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->},{_,_->error("no batch")},{},
            previewPreparation={entered.complete(Unit);withContext(NonCancellable) {finish.await()};ResourcePreparationCancellationPlan(id(),row.id,1)},
            cancelPreparation={commits++;ResourcePreparationCancellationResult(1,1,0)})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelPreparation);entered.await();owner.foreground(false);finish.complete(Unit);yield()
            assertNull(owner.state.confirmation);assertFalse(owner.state.working);assertFalse(owner.state.available);owner.confirm();assertEquals(0,commits)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun mismatchedPreviewAndRejectedCommitRequireFreshReviewWithoutShowingSuccess()=runBlocking<Unit> {
        val row=row();var wrong=true;var commits=0
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->error("no direct action")},{_,_->error("no batch")},{},
            previewPreparation={ResourcePreparationCancellationPlan(id(),if(wrong) row.id.copy(value=id()) else row.id,1)},
            cancelPreparation={commits++;throw ResourceTransferActionUnavailable()})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelPreparation);until {!owner.state.working}
            assertNull(owner.state.confirmation);assertNotNull(owner.state.feedback)
            wrong=false;owner.act(row.id,ResourceTransferAction.CancelPreparation);until {owner.state.confirmation!=null && !owner.state.working};owner.confirm();until {!owner.state.working}
            assertEquals(1,commits);assertNull(owner.state.confirmation);assertFalse(owner.state.feedback!!.contains("已取消 1 条"));owner.confirm();assertEquals(1,commits)
        } finally {owner.close()}
    }
    @Test fun readFailureClearsAReviewedPreparationPlanAndMultiSelectCannotStartIt()=runBlocking<Unit> {
        val row=row().copy(group=ResourceTransferGroup.Attention);val changes=MutableStateFlow(0L);var fail=false;var previews=0;var commits=0
        val owner=ResourceTransfersController(this,changes,{if(fail) error("closed") else ResourceTransferPage(persistentListOf(row))},{_,_->},{_,_->error("no batch")},{},
            previewPreparation={previews++;ResourcePreparationCancellationPlan(id(),row.id,1)},cancelPreparation={commits++;ResourcePreparationCancellationResult(1,1,0)})
        try {
            owner.foreground(true);owner.query(ResourceTransferGroup.Attention);until {owner.state.available};owner.selectMode();owner.act(row.id,ResourceTransferAction.CancelPreparation);assertEquals(0,previews)
            owner.selectMode();owner.act(row.id,ResourceTransferAction.CancelPreparation);until {owner.state.confirmation!=null && !owner.state.working}
            fail=true;changes.value++;until {!owner.state.available};assertNull(owner.state.confirmation);owner.confirm();assertEquals(0,commits)
        } finally {owner.close()}
    }
    @Test fun composeShowsReviewedWholeMessageScopeAndOnlyConfirmationCommits() {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val state=mutableStateOf(ResourceTransfersState());val row=row();val plan=ResourcePreparationCancellationPlan(id(),row.id,1)
        var previews=0;var commits=0;lateinit var owner:ResourceTransfersController
        compose.runOnIdle {owner=ResourceTransfersController(scope,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->error("no direct action")},{_,_->error("no batch")},{state.value=it},
            previewPreparation={previews++;plan},cancelPreparation={assertEquals(plan,it);commits++;ResourcePreparationCancellationResult(1,1,2)});owner.foreground(true)}
        try {
            compose.setContent {MaterialTheme {ResourceTransfersScreen(state.value,true,false,owner::query,owner::page,owner::reload,owner::act,owner::selectMode,owner::select,owner::selectPage,owner::retry,owner::confirm,owner::dismiss,{},{_,_->})}}
            compose.waitUntil {state.value.available};compose.onNodeWithTag("transfer-CancelPreparation-${row.id.key}").performScrollTo().performClick()
            compose.waitUntil {state.value.confirmation!=null && !state.value.working}
            compose.onNodeWithText("取消待发送消息？").assertIsDisplayed();compose.onNodeWithText("将取消 1 条尚未交给发送队列的消息",substring=true).assertIsDisplayed();assertEquals(0,commits)
            if(InstrumentationRegistry.getArguments().getString("capturePreparationUI")=="true") {
                val bitmap=compose.onNode(isDialog()).captureToImage().asAndroidBitmap()
                java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"preparation-cancel-confirmation.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            }
            compose.onNodeWithText("返回").performClick();assertEquals(0,commits)
            compose.onNodeWithTag("transfer-CancelPreparation-${row.id.key}").performClick();compose.waitUntil {state.value.confirmation!=null && !state.value.working}
            compose.onNodeWithTag("transfer-confirm-cancel").performClick();compose.waitUntil {commits==1 && !state.value.working}
            compose.onNodeWithTag("transfers-feedback").assertTextContains("已取消 1 条待发送消息",substring=true);assertEquals(2,previews)
        } finally {compose.runOnIdle {owner.close()};scope.cancel()}
    }
}
