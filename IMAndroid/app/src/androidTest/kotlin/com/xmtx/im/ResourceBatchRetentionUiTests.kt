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

class ResourceBatchRetentionUiTests {
    @get:Rule val compose=createComposeRule()
    private val room=RoomId(UUID.randomUUID().toString().uppercase())
    private fun key()=ResourceKey(ResourceHome.Room(room),UUID.randomUUID().toString().uppercase())
    private val first=key();private val other=key();private val missing=key()
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    private fun result(value:Boolean,vararg items:Pair<ResourceKey,ResourceRetentionBatchOutcome>)=ResourceRetentionBatchResult(value,items.map {ResourceRetentionBatchItem(it.first,it.second)}.toPersistentList())
    @Test fun commandFreezesSelectionAndOnlyFailedItemsRemainForExplicitRetry()=runBlocking<Unit> {
        val finish=CompletableDeferred<Unit>();val calls=mutableListOf<PersistentList<ResourceKey>>()
        val owner=ResourceSelectionController(this,{error("must not preview")},{error("must not clean")},{},retain={keys,value->
            calls.add(keys);if(calls.size==1) {finish.await();result(value,first to ResourceRetentionBatchOutcome.Changed,other to ResourceRetentionBatchOutcome.LimitReached,missing to ResourceRetentionBatchOutcome.Unavailable)}
            else result(value,other to ResourceRetentionBatchOutcome.Unchanged)
        })
        try {
            owner.foreground(true);owner.toggleMode();owner.selectPage(persistentListOf(first,other,missing));owner.setRetained(true)
            owner.setRetained(false);owner.toggle(first);owner.toggleMode();owner.prepare();until {calls.size==1}
            assertEquals(persistentListOf(first,other,missing),owner.state.selected)
            finish.complete(Unit);until {!owner.state.working};assertEquals(persistentListOf(other),owner.state.selected);assertEquals(1,owner.state.retentionResult!!.changedCount)
            assertEquals(1,calls.size);owner.setRetained(true);until {calls.size==2 && !owner.state.working}
            assertEquals(persistentListOf(other),calls.last());assertTrue(owner.state.selected!!.isEmpty());assertEquals(1,owner.state.retentionResult!!.unchangedCount)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun lateBatchResultCannotRestoreSelectionAfterBackgroundOrQueryReset()=runBlocking<Unit> {
        for(background in listOf(true,false)) {
            val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
            val owner=ResourceSelectionController(this,{error("not used")},{error("not used")},{},retain={_,value->entered.complete(Unit);withContext(NonCancellable) {finish.await()};result(value,first to ResourceRetentionBatchOutcome.Failed)})
            try {
                owner.foreground(true);owner.toggleMode();owner.toggle(first);owner.setRetained(true);entered.await()
                if(background) {owner.foreground(false);owner.foreground(true)} else owner.reset()
                finish.complete(Unit);delay(50);assertEquals(ResourceSelectionState(),owner.state)
            } finally {finish.complete(Unit);owner.close()}
        }
    }
    @Test fun lostOrMismatchedResultNeverClaimsThatAllItemsFailedOrSucceeded()=runBlocking<Unit> {
        for(mismatch in listOf(false,true)) {
            var calls=0
            val owner=ResourceSelectionController(this,{error("not used")},{error("not used")},{},retain={_,value->calls++;if(mismatch) result(value,other to ResourceRetentionBatchOutcome.Changed) else error("response lost after a commit")})
            try {
                owner.foreground(true);owner.toggleMode();owner.toggle(first);owner.setRetained(false);until {!owner.state.working}
                assertNull(owner.state.retentionResult);assertEquals(persistentListOf(first),owner.state.selected)
                assertTrue(owner.state.feedback!!.contains("部分项目可能已更新"));assertEquals(1,calls)
            } finally {owner.close()}
        }
    }
    @Test fun anOpenCleanupPreviewPreventsRetentionFromMutatingItsFrozenSelection()=runBlocking<Unit> {
        var calls=0;val preview=ResourceSelectionCleanupPlan(ResourceCleanupPlan("preview",1,4096,0),1,0,0)
        val owner=ResourceSelectionController(this,{preview},{error("not used")},{},retain={_,value->calls++;result(value,first to ResourceRetentionBatchOutcome.Changed)})
        try {
            owner.foreground(true);owner.toggleMode();owner.toggle(first);owner.prepare();until {owner.state.preview!=null};owner.setRetained(true)
            assertEquals(0,calls);assertEquals(preview,owner.state.preview)
        } finally {owner.close()}
    }
    @Test fun libraryButtonsReportPartialResultsAndReleaseOnlyTheRemainingSelection() {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val state=mutableStateOf(ResourceLibraryState());var calls=0
        val page=ResourceCatalogPage(listOf(first,other,missing).map {ResourceCatalogEntry(ResourceDescriptor(it,1,"文件-${it.media.take(4)}","text/plain",10,ResourceChecksum("a".repeat(64)),ResourceState.Ready),1,1)}.toPersistentList(),null,false)
        val owner=ResourceLibraryController(scope,MutableStateFlow(0L),{page},{state.value=it},retain={keys,value->
            calls++
            if(calls==1) {assertTrue(value);assertEquals(listOf(first,other,missing),keys);result(true,first to ResourceRetentionBatchOutcome.Changed,other to ResourceRetentionBatchOutcome.LimitReached,missing to ResourceRetentionBatchOutcome.Unavailable)}
            else {assertFalse(value);assertEquals(persistentListOf(other),keys);result(false,other to ResourceRetentionBatchOutcome.Unchanged)}
        })
        try {
            compose.setContent {MaterialTheme {ResourceLibraryScreen(state.value,true,false,owner::query,owner::page,owner::reload,{},toggleSelection=owner::toggleSelection,select=owner::select,selectPage=owner::selectPage,retainSelection=owner::retainSelection)}}
            compose.runOnIdle {owner.foreground(true)};compose.waitUntil(5000) {!state.value.loading && state.value.entries.size==3}
            compose.onNodeWithTag("resource-select-mode").performClick();compose.onNodeWithTag("resource-selected-retain").assertIsNotEnabled()
            compose.onNodeWithTag("resource-select-page").performClick();compose.onNodeWithTag("resource-selected-retain").performClick()
            compose.waitUntil(5000) {state.value.selection.retentionResult!=null}
            compose.onNodeWithTag("resource-retention-result").assertTextContains("已更新 1 项，跳过 1 项，失败 1 项",substring=true)
            compose.onNodeWithTag("resource-retention-result").assertTextContains("失败项仍被选中",substring=true)
            if(InstrumentationRegistry.getArguments().getString("captureBatchRetention")=="true") {
                InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput("batch-retention-result.png",0).use {compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            }
            compose.onNodeWithTag("resource-selected-release").performClick();compose.waitUntil(5000) {calls==2 && !state.value.selection.working}
            compose.onNodeWithTag("resource-retention-result").assertTextContains("解除保留：已更新 0 项，跳过 1 项，失败 0 项",substring=true)
            compose.onNodeWithTag("resource-selected-retain").assertIsNotEnabled();compose.onNodeWithTag("resource-selected-release").assertIsNotEnabled()
        } finally {compose.runOnIdle {owner.close()};scope.cancel()}
    }
}
