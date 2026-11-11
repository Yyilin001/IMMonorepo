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

class ResourceSelectionCleanupUiTests {
    @get:Rule val compose=createComposeRule()
    private val room=RoomId(UUID.randomUUID().toString().uppercase())
    private fun key()=ResourceKey(ResourceHome.Room(room),UUID.randomUUID().toString().uppercase())
    private val first=key();private val other=key()
    private val plan=ResourceSelectionCleanupPlan(ResourceCleanupPlan("preview",1,4096,1),2,0,0)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    private fun page(vararg keys:ResourceKey)=ResourceCatalogPage(keys.map {ResourceCatalogEntry(ResourceDescriptor(it,1,"文件-${it.media.take(4)}","text/plain",20,ResourceChecksum("a".repeat(64)),ResourceState.Ready),1,1)}.toPersistentList(),null,false)
    private fun capture(name:String,node:SemanticsNodeInteraction) {
        if(InstrumentationRegistry.getArguments().getString("captureSelectionCleanup")!="true") return
        // Capture the Compose window surface, excluding WindowManager's fade
        // compositing with a different window underneath the dialog.
        InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput(name,0).use {
            node.captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)
        }
    }

    @Test fun selectionIsBoundedDeduplicatedAndPageSelectionReplacesThePreviousSet()=runBlocking<Unit> {
        val owner=ResourceSelectionController(this,{plan},{error("must not commit")},{})
        try {
            owner.foreground(true);owner.toggleMode();val values=List(101) {key()};values.forEach(owner::toggle)
            assertEquals(100,owner.state.selected!!.size);owner.toggle(values.first());assertEquals(99,owner.state.selected!!.size)
            owner.selectPage(persistentListOf(first,other,first));assertEquals(persistentListOf(first,other),owner.state.selected)
            owner.reset();assertNull(owner.state.selected);owner.toggle(first);assertNull(owner.state.selected)
        } finally {owner.close()}
    }
    @Test fun previewFreezesSelectionAndDuplicateConfirmationDoesNotRepeatTheCommit()=runBlocking<Unit> {
        var captured:PersistentList<ResourceKey>?=null;var commits=0;val finish=CompletableDeferred<Unit>()
        val owner=ResourceSelectionController(this,{captured=it;plan},{commits++;finish.await();ResourceCleanupResult(1,4096,1,0)},{})
        try {
            owner.foreground(true);owner.toggleMode();owner.selectPage(persistentListOf(first,other));owner.prepare();until {owner.state.preview!=null}
            owner.toggle(first);owner.toggleMode();owner.selectPage(persistentListOf(other));assertEquals(captured,owner.state.selected);assertEquals(0,commits)
            owner.confirm();owner.confirm();until {commits==1};finish.complete(Unit);until {!owner.state.working}
            assertEquals(ResourceCleanupResult(1,4096,1,0),owner.state.result);assertEquals(persistentListOf<ResourceKey>(),owner.state.selected)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun latePreviewAndCommitCannotRepopulateAnExitedOrReenteredPage()=runBlocking<Unit> {
        for(committing in listOf(false,true)) {
            val started=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
            val owner=ResourceSelectionController(this,{if(!committing) {started.complete(Unit);withContext(NonCancellable) {finish.await()}};plan},
                {started.complete(Unit);withContext(NonCancellable) {finish.await()};ResourceCleanupResult(1,4096,0,0)},{})
            try {
                owner.foreground(true);owner.toggleMode();owner.toggle(first);owner.prepare()
                if(committing) {until {owner.state.preview!=null};owner.confirm()}
                started.await();owner.foreground(false);owner.foreground(true);finish.complete(Unit);delay(50)
                assertEquals(ResourceSelectionState(),owner.state)
            } finally {finish.complete(Unit);owner.close()}
        }
    }
    @Test fun dismissalAndFailedCommitRequireANewExplicitPreview()=runBlocking<Unit> {
        var calls=0;val owner=ResourceSelectionController(this,{plan},{calls++;error("expired")},{})
        try {
            owner.foreground(true);owner.toggleMode();owner.toggle(first);owner.prepare();until {owner.state.preview!=null}
            owner.dismiss();owner.confirm();assertEquals(0,calls)
            owner.prepare();until {owner.state.preview!=null};owner.confirm();until {!owner.state.working}
            assertNull(owner.state.preview);assertNotNull(owner.state.feedback);assertEquals(persistentListOf(first),owner.state.selected)
            owner.confirm();assertEquals(1,calls)
        } finally {owner.close()}
    }
    @Test fun libraryQueryChangesAndReadFailureClearOldSelectionAuthority()=runBlocking<Unit> {
        val changes=MutableStateFlow(0L);var failure=false
        val owner=ResourceLibraryController(this,changes,{if(failure) error("revoked");page(first,other)},{},preview={plan},commit={error("must not commit")})
        try {
            owner.foreground(true);until {!owner.state.loading};owner.toggleSelection();owner.select(first);owner.previewSelection();until {owner.state.selection.preview!=null}
            owner.query("next",ResourceCategory.All,false);until {!owner.state.loading};assertEquals(ResourceSelectionState(),owner.state.selection)
            owner.toggleSelection();owner.select(other);failure=true;changes.value++;until {owner.state.feedback!=null}
            assertEquals(ResourceSelectionState(),owner.state.selection);assertTrue(owner.state.entries.isEmpty())
        } finally {owner.close()}
    }
    @Test fun actualLibrarySelectionShowsCountsAndOnlyAnExplicitConfirmationDeletes() {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val value=mutableStateOf(ResourceLibraryState());var commits=0;var opens=0
        val owner=ResourceLibraryController(scope,MutableStateFlow(0L),{page(first,other)},{value.value=it},preview={plan},commit={commits++;ResourceCleanupResult(1,4096,1,0)})
        try {
            compose.setContent {MaterialTheme {ResourceLibraryScreen(value.value,true,false,owner::query,owner::page,owner::reload,{opens++},
                toggleSelection=owner::toggleSelection,select=owner::select,selectPage=owner::selectPage,previewSelection=owner::previewSelection,confirmSelection=owner::confirmSelection,dismissSelection=owner::dismissSelection)}}
            compose.runOnIdle {owner.foreground(true)};compose.waitUntil(5000) {!value.value.loading && value.value.entries.size==2}
            compose.onNodeWithTag("resource-select-mode").performClick();compose.onNodeWithTag("resource-select-page").performClick()
            compose.onNodeWithTag("resource-selected-preview").performClick();compose.waitUntil(5000) {value.value.selection.preview!=null}
            compose.onNodeWithTag("resource-selected-summary").assertTextContains("所选资源：2 个",substring=true)
            compose.onNodeWithTag("resource-selected-summary").assertTextContains("受保护文件：1 个",substring=true)
            capture("selection-cleanup-preview.png",compose.onNode(isDialog()))
            compose.runOnIdle {assertEquals(0,commits);assertEquals(0,opens)}
            compose.onNodeWithTag("resource-selected-dismiss").performClick();compose.runOnIdle {assertEquals(0,commits)}
            compose.onNodeWithTag("resource-selected-preview").performClick();compose.waitUntil(5000) {value.value.selection.preview!=null}
            compose.onNodeWithTag("resource-selected-confirm").performClick();compose.waitUntil(5000) {value.value.selection.result!=null}
            compose.onNodeWithTag("resource-selection-result").assertTextContains("已清理 1 个本机文件",substring=true)
            capture("selection-cleanup-result.png",compose.onRoot())
            compose.runOnIdle {assertEquals(1,commits)}
        } finally {compose.runOnIdle {owner.close()};scope.cancel()}
    }
    @Test fun emptySelectionPlanCannotConfirmAndInactiveScreenHidesTheDialog() {
        val active=mutableStateOf(true);var calls=0
        val empty=ResourceSelectionCleanupPlan(ResourceCleanupPlan("empty",0,0,0),2,1,1)
        val state=ResourceLibraryState(available=true,selection=ResourceSelectionState(selected=persistentListOf(first,other),preview=empty))
        compose.setContent {MaterialTheme {ResourceLibraryScreen(state,active.value,false,{_,_,_->},{},{},{},confirmSelection={calls++})}}
        compose.onNodeWithTag("resource-selected-confirm").assertIsNotEnabled();compose.onNodeWithTag("resource-selected-summary").assertTextContains("未下载资源：1 个",substring=true)
        compose.runOnIdle {active.value=false};compose.onNodeWithTag("resource-selected-summary").assertDoesNotExist();compose.runOnIdle {assertEquals(0,calls)}
    }
}
