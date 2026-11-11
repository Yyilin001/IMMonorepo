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

class ResourceTransfersUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=ResourceTransferId(ResourceTransferKind.Upload,UUID.randomUUID().toString().uppercase())
    private fun row(key:ResourceTransferId=id(),group:ResourceTransferGroup=ResourceTransferGroup.Attention)=ManagedResourceTransfer(key,100,"文件.txt",ResourceUsage.UserAvatar,null,group,ResourceTransferPhase.RequiresAttention,
        actions=persistentSetOf(ResourceTransferAction.Retry,ResourceTransferAction.CancelUnbound))
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun waitingSnapshotsDoNotRereadDatabaseOrReviveOldPages()=runBlocking<Unit> {
        val hub=ResourceTransferWaiting();val entry=row(group=ResourceTransferGroup.Active).copy(phase=ResourceTransferPhase.Preparing)
        var reads=0
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{query->reads++;ResourceTransferPage(if(query.group==ResourceTransferGroup.Active) persistentListOf(entry) else persistentListOf())},{_,_->},{_,_->error("unused")},{},observations=hub.snapshots)
        try {
            owner.foreground(true);until {owner.state.available};assertEquals(1,reads)
            val observation=hub.begin(entry.id,ResourceTransferWaitingReason.RequestSlot)!!
            until {owner.state.page.entries.single().waitingReason==ResourceTransferWaitingReason.RequestSlot}
            observation.update(ResourceTransferWaitingReason.ServiceCooldown)
            until {owner.state.page.entries.single().waitingReason==ResourceTransferWaitingReason.ServiceCooldown};assertEquals(1,reads)
            observation.end();until {owner.state.page.entries.single().waitingReason==null};assertEquals(1,reads)
            owner.query(ResourceTransferGroup.Finished);until {owner.state.available};assertTrue(owner.state.page.entries.isEmpty())
            hub.begin(entry.id,ResourceTransferWaitingReason.TransferSlot);yield();assertTrue(owner.state.page.entries.isEmpty());assertEquals(2,reads)
            owner.foreground(false);hub.close();yield();assertFalse(owner.state.available);assertTrue(owner.state.page.entries.isEmpty())
        } finally {owner.close();hub.close()}
    }
    @Test fun waitingReasonsRenderAndClearWhileTaskControlsRemainAvailable() {
        val entry=row(group=ResourceTransferGroup.Active).copy(phase=ResourceTransferPhase.Transferring,actions=persistentSetOf(ResourceTransferAction.Pause),totalBytes=1024)
        val hub=ResourceTransferWaiting();val state=mutableStateOf(ResourceTransfersState());val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        lateinit var owner:ResourceTransfersController
        compose.runOnIdle {owner=ResourceTransfersController(scope,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(entry))},{_,_->},{_,_->error("unused")},{state.value=it},observations=hub.snapshots);owner.foreground(true)}
        try {
            compose.setContent {MaterialTheme {ResourceTransfersScreen(state.value,true,false,owner::query,owner::page,owner::reload,owner::act,owner::selectMode,owner::select,owner::selectPage,owner::retry,owner::confirm,owner::dismiss,{}, {_,_->})}}
            compose.waitUntil {state.value.available}
            val wait=hub.begin(entry.id,ResourceTransferWaitingReason.TransferSlot)!!
            compose.waitUntil {state.value.page.entries.single().waitingReason==ResourceTransferWaitingReason.TransferSlot}
            compose.onNodeWithText("上传 · 等待传输名额").performScrollTo().assertIsDisplayed()
            compose.onNodeWithTag("transfer-Pause-${entry.id.key}").assertIsEnabled()
            wait.update(ResourceTransferWaitingReason.RequestSlot)
            compose.waitUntil {state.value.page.entries.single().waitingReason==ResourceTransferWaitingReason.RequestSlot}
            compose.onNodeWithText("上传 · 等待请求名额").assertIsDisplayed()
            wait.update(ResourceTransferWaitingReason.ServiceCooldown)
            compose.waitUntil {state.value.page.entries.single().waitingReason==ResourceTransferWaitingReason.ServiceCooldown}
            compose.onNodeWithText("上传 · 等待服务恢复额度").assertIsDisplayed()
            val bitmap=compose.onRoot().captureToImage().asAndroidBitmap()
            java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"transfers-waiting.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            wait.update(ResourceTransferWaitingReason.Network)
            compose.waitUntil {state.value.page.entries.single().waitingReason==ResourceTransferWaitingReason.Network}
            compose.onNodeWithText("上传 · 等待网络").assertIsDisplayed()
            wait.update(ResourceTransferWaitingReason.NetworkPolicy)
            compose.waitUntil {state.value.page.entries.single().waitingReason==ResourceTransferWaitingReason.NetworkPolicy}
            compose.onNodeWithText("上传 · 等待允许自动下载的网络").assertIsDisplayed()
            wait.end();compose.waitUntil {state.value.page.entries.single().waitingReason==null}
            compose.onNodeWithText("上传 · 正在传输").assertIsDisplayed();compose.onNodeWithTag("transfer-wait-${entry.id.key}").assertDoesNotExist()
        } finally {compose.runOnIdle {owner.close()};hub.close();scope.cancel()}
    }
    @Test fun attemptProgressDoesNotConfirmBytesOrRereadDatabaseAndClearsOnPause() {
        val entry=row(group=ResourceTransferGroup.Active).copy(phase=ResourceTransferPhase.Confirming,totalBytes=100,confirmedBytes=40,actions=persistentSetOf(ResourceTransferAction.Pause))
        val hub=ResourceTransferWaiting();val state=mutableStateOf(ResourceTransfersState());val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val changes=MutableStateFlow(0L);var stored=entry;var reads=0;lateinit var owner:ResourceTransfersController
        compose.runOnIdle {owner=ResourceTransfersController(scope,changes,{reads++;ResourceTransferPage(persistentListOf(stored))},{_,_->},{_,_->error("unused")},{state.value=it},observations=hub.snapshots);owner.foreground(true)}
        try {
            compose.setContent {MaterialTheme {ResourceTransfersScreen(state.value,true,false,owner::query,owner::page,owner::reload,owner::act,owner::selectMode,owner::select,owner::selectPage,owner::retry,owner::confirm,owner::dismiss,{}, {_,_->})}}
            compose.waitUntil {state.value.available};val baseline=reads
            val waiting=hub.begin(entry.id,ResourceTransferWaitingReason.RequestSlot)!!
            val attempt=hub.beginAttempt(entry.id,20)!!;attempt.report(10)
            compose.waitUntil {state.value.page.entries.single().attemptProgress?.transferredBytes==10L}
            compose.onNodeWithTag("transfer-progress-${entry.id.key}").performScrollTo().assertRangeInfoEquals(androidx.compose.ui.semantics.ProgressBarRangeInfo(.5f,0f..1f))
            compose.onNodeWithTag("transfer-progress-label-${entry.id.key}").assertTextContains("本次上传",substring=true)
            compose.onNodeWithTag("transfer-wait-${entry.id.key}").assertDoesNotExist()
            attempt.report(20);compose.waitUntil {state.value.page.entries.single().attemptProgress?.transferredBytes==20L}
            compose.onNodeWithTag("transfer-progress-${entry.id.key}").assertRangeInfoEquals(androidx.compose.ui.semantics.ProgressBarRangeInfo(1f,0f..1f))
            compose.onNodeWithText("上传 · 正在传输").assertIsDisplayed()
            assertEquals(40L,state.value.page.entries.single().confirmedBytes);assertEquals(baseline,reads)
            val bitmap=compose.onRoot().captureToImage().asAndroidBitmap()
            java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"transfers-progress.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            compose.runOnIdle {stored=entry.copy(phase=ResourceTransferPhase.Paused);changes.value++}
            compose.waitUntil {state.value.page.entries.single().phase==ResourceTransferPhase.Paused}
            compose.onNodeWithTag("transfer-progress-${entry.id.key}").assertDoesNotExist()
            assertEquals(baseline+1,reads);attempt.end();waiting.end()
            compose.runOnIdle {owner.foreground(false)};hub.beginAttempt(entry.id,20)?.report(1)
            compose.waitForIdle();assertTrue(state.value.page.entries.isEmpty())
        } finally {compose.runOnIdle {owner.close()};hub.close();scope.cancel()}
    }
    @Test fun batchFreezesSelectionAndOnlyFailedItemsRemainWithoutResumingPausedTasks()=runBlocking<Unit> {
        val first=row();val second=row();val paused=row().copy(phase=ResourceTransferPhase.Paused,actions=persistentSetOf(ResourceTransferAction.Resume))
        val finish=CompletableDeferred<Unit>();val calls=mutableListOf<PersistentList<ResourceTransferId>>()
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(first,second,paused))},{_,_->error("no single action")},{ids,action->
            calls+=ids;finish.await();ResourceTransferBatchResult(action,persistentListOf(ResourceTransferBatchItem(first.id,ResourceTransferBatchOutcome.Requested),ResourceTransferBatchItem(second.id,ResourceTransferBatchOutcome.Failed),ResourceTransferBatchItem(paused.id,ResourceTransferBatchOutcome.Skipped)))
        },{})
        try {
            owner.foreground(true);owner.query(ResourceTransferGroup.Attention);until {owner.state.available};owner.selectMode();owner.selectPage();owner.retry(ResourceTransferAction.Retry)
            owner.select(first.id);owner.query(ResourceTransferGroup.Finished);owner.retry(ResourceTransferAction.RetryCancellation);until {calls.size==1}
            assertEquals(3,owner.state.selected!!.size);assertEquals(ResourceTransferGroup.Attention,owner.state.group)
            finish.complete(Unit);until {!owner.state.working};assertEquals(persistentListOf(second.id),owner.state.selected);assertEquals(1,owner.state.result!!.skippedCount)
            assertEquals(1,calls.size)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun lateQueryAndBackgroundResultsCannotRepopulateTheCurrentPage()=runBlocking<Unit> {
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();val old=row(group=ResourceTransferGroup.Active)
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{query->
            if(query.group==ResourceTransferGroup.Active) {entered.complete(Unit);withContext(NonCancellable) {finish.await()};ResourceTransferPage(persistentListOf(old))}
            else ResourceTransferPage(persistentListOf())
        },{_,_->},{_,_->error("no batch")},{})
        try {
            owner.foreground(true);entered.await();owner.query(ResourceTransferGroup.Finished);until {owner.state.available};finish.complete(Unit);yield()
            assertEquals(ResourceTransferGroup.Finished,owner.state.group);assertTrue(owner.state.page.entries.isEmpty())
            owner.foreground(false);assertFalse(owner.state.available);assertNull(owner.state.selected);assertTrue(owner.state.page.entries.isEmpty())
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun readFailureDisablesActionsAndInvalidatesPendingConfirmation()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);val row=row();var fail=false;var calls=0
        val owner=ResourceTransfersController(this,changes,{if(fail) error("unavailable") else ResourceTransferPage(persistentListOf(row))},{_,_->calls++},{_,_->error("no batch")},{},previewUnbound={ResourceUnboundCancellationPlan(UUID.randomUUID().toString().uppercase(),it)},cancelUnbound={calls++})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.CancelUnbound);until {owner.state.confirmation!=null && !owner.state.working}
            fail=true;changes.value++;until {!owner.state.available && !owner.state.loading};assertNull(owner.state.confirmation)
            owner.confirm();owner.act(row.id,ResourceTransferAction.Retry);assertEquals(0,calls)
            fail=false;owner.reload();until {owner.state.available};owner.act(row.id,ResourceTransferAction.Retry);until {calls==1 && !owner.state.working}
        } finally {owner.close()}
    }
    @Test fun backgroundDuringCommandDropsItsLateFeedbackAndSelection()=runBlocking<Unit> {
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();val row=row()
        val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->entered.complete(Unit);withContext(NonCancellable) {finish.await()}},{_,_->error("no batch")},{})
        try {
            owner.foreground(true);until {owner.state.available};owner.act(row.id,ResourceTransferAction.Retry);entered.await();owner.foreground(false);finish.complete(Unit);yield()
            assertFalse(owner.state.working);assertNull(owner.state.feedback);assertTrue(owner.state.page.entries.isEmpty());assertFalse(owner.state.available)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun failedOrMismatchedBatchResultDoesNotPretendAllItemsFailedOrClearSelection()=runBlocking<Unit> {
        val row=row();val owner=ResourceTransfersController(this,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(row))},{_,_->},{_,action->ResourceTransferBatchResult(action,persistentListOf(ResourceTransferBatchItem(id(),ResourceTransferBatchOutcome.Requested)))},{})
        try {
            owner.foreground(true);owner.query(ResourceTransferGroup.Attention);until {owner.state.available};owner.selectMode();owner.selectPage();owner.retry(ResourceTransferAction.Retry)
            until {!owner.state.working};assertNull(owner.state.result);assertEquals(persistentListOf(row.id),owner.state.selected);assertNotNull(owner.state.feedback)
        } finally {owner.close()}
    }
    @Test fun screenRequiresCancellationConfirmationAndReflectsPausedAndBatchResults() {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val value=mutableStateOf(ResourceTransfersState());val first=row()
        val paused=row().copy(displayName="已暂停的头像",phase=ResourceTransferPhase.Paused,actions=persistentSetOf(ResourceTransferAction.Resume),hasBusinessOwners=true)
        var controls=0;var related=0;lateinit var owner:ResourceTransfersController
        compose.runOnIdle {owner=ResourceTransfersController(scope,MutableStateFlow(0L),{ResourceTransferPage(persistentListOf(first,paused))},{_,_->controls++},{ids,action->ResourceTransferBatchResult(action,ids.map {ResourceTransferBatchItem(it,if(it==first.id) ResourceTransferBatchOutcome.Failed else ResourceTransferBatchOutcome.Skipped)}.toPersistentList())},{value.value=it},previewUnbound={ResourceUnboundCancellationPlan(UUID.randomUUID().toString().uppercase(),it)},cancelUnbound={controls++});owner.foreground(true);owner.query(ResourceTransferGroup.Attention)}
        try {
            compose.setContent {MaterialTheme {ResourceTransfersScreen(value.value,true,false,owner::query,owner::page,owner::reload,owner::act,owner::selectMode,owner::select,owner::selectPage,owner::retry,owner::confirm,owner::dismiss,{}, {_,_->related++})}}
            compose.waitUntil {value.value.available}
            compose.onNodeWithTag("transfer-CancelUnbound-${first.id.key}").performScrollTo().performClick();compose.onNodeWithTag("transfer-cancellation-confirmation").assertIsDisplayed();assertEquals(0,controls)
            if(InstrumentationRegistry.getArguments().getString("captureUnboundUI")=="true") {
                val bitmap=compose.onNode(isDialog()).captureToImage().asAndroidBitmap()
                java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"unbound-cancel-confirmation.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            }
            compose.onNodeWithText("返回").performClick();assertEquals(0,controls)
            compose.onNodeWithTag("transfer-CancelUnbound-${first.id.key}").performClick();compose.onNodeWithTag("transfer-confirm-cancel").performClick();compose.waitUntil {controls==1 && !value.value.working}
            compose.onNodeWithTag("transfers-select-mode").performScrollTo().performClick();compose.onNodeWithText("选择本页").performClick();compose.onNodeWithTag("transfers-batch-Retry").performClick()
            compose.waitUntil {value.value.result!=null && !value.value.working};compose.onNodeWithTag("transfers-result").assertTextContains("已请求 0 · 跳过 1 · 失败 1",substring=true)
            compose.onNodeWithTag("transfer-Resume-${paused.id.key}").assertIsNotEnabled()
            if(InstrumentationRegistry.getArguments().getString("captureTransferUI")=="true") {
                val bitmap=compose.onRoot().captureToImage().asAndroidBitmap()
                java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"transfers-ui-batch.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            }
        } finally {compose.runOnIdle {owner.close()};scope.cancel()}
    }
}
