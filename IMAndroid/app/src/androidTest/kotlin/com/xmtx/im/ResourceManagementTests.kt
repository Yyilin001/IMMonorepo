package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ResourceManagementTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id());private val key=ResourceKey(ResourceHome.Room(room),id())
    private val descriptor=ResourceDescriptor(key,1,"项目说明.pdf","application/pdf",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private val source=MessageResourceSource(room,MessageId(id()),0,1)
    private fun snapshot(retained:Boolean=false)=ResourceDetailSnapshot(descriptor,persistentListOf(ResourceVariantSnapshot(ResourceVariantDescriptor(ResourceVariantKey(key),descriptor.checksum!!,100),retained,false)),ResourceSourcePage(persistentListOf(source),null))
    private val page=ResourceCatalogPage(persistentListOf(ResourceCatalogEntry(descriptor,100,1)),null,false)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}

    @Test fun libraryCombinesFiltersResetsPagingAndDropsLateReadsOnLeave()=runBlocking {
        val changes=MutableStateFlow(0L);val queries=mutableListOf<ResourceCatalogQuery>();val started=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        var slow=false
        val owner=ResourceLibraryController(this,changes,{q->queries.add(q);if(slow) {started.complete(Unit);withContext(NonCancellable) {release.await()}};page.copy(nextCursor=ResourceCatalogCursor(100,key))},{})
        try {
            owner.foreground(true);until {!owner.state.loading};owner.page(true);until {!owner.state.loading};assertEquals(2,owner.state.positions.size)
            owner.query("项目",ResourceCategory.File,true);until {!owner.state.loading};assertEquals(1,owner.state.positions.size)
            assertTrue(queries.last().retainedOnly);assertEquals(ResourceCategory.File,queries.last().category);assertEquals("项目",queries.last().search)
            slow=true;changes.value++;started.await();assertEquals(page.entries,owner.state.entries);owner.foreground(false);release.complete(Unit);delay(20)
            assertFalse(owner.state.available);assertTrue(owner.state.entries.isEmpty())
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun detailSerializesWritesAndRevocationDisablesEveryAction()=runBlocking {
        val changes=MutableStateFlow(0L);var visible=true;var retained=false;var writes=0
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val owner=ResourceDetailController(key,this,changes,{_,_->if(visible) snapshot(retained) else null},{_,value->writes++;entered.complete(Unit);release.await();retained=value;changes.value++},{})
        try {
            owner.foreground(true);until {owner.state.usable};owner.setRetained(true);owner.setRetained(true);entered.await();assertEquals(1,writes);assertFalse(owner.state.usable)
            release.complete(Unit);until {owner.state.original?.retained==true && !owner.state.working}
            visible=false;changes.value++;until {owner.state.snapshot==null && !owner.state.loading};owner.setRetained(false);assertEquals(1,writes)
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun lateCommittedRetentionCannotReviveAnInactiveDetail()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var writes=0
        val owner=ResourceDetailController(key,this,MutableStateFlow(0L),{_,_->snapshot()},{_,_->entered.complete(Unit);withContext(NonCancellable) {release.await();writes++}},{})
        try {
            owner.foreground(true);until {owner.state.usable};owner.setRetained(true);entered.await();owner.foreground(false);release.complete(Unit);until {writes==1};delay(20)
            assertNull(owner.state.snapshot);assertNull(owner.state.feedback);assertFalse(owner.state.available);assertFalse(owner.state.working)
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun detailReadFailureRemovesOldMetadataAndPagingUsesExplicitCursors()=runBlocking {
        val changes=MutableStateFlow(0L);val cursor=ResourceSourceCursor(source.message,0);var fail=false;val cursors=mutableListOf<ResourceSourceCursor?>()
        val owner=ResourceDetailController(key,this,changes,{_,before->cursors.add(before);if(fail) error("read failed");snapshot().copy(sources=ResourceSourcePage(persistentListOf(source),if(before==null) cursor else null))},{_,_->},{})
        try {
            owner.foreground(true);until {owner.state.usable};owner.page(true);until {owner.state.usable};assertEquals(cursor,cursors.last())
            owner.page(false);until {owner.state.usable};assertNull(cursors.last())
            fail=true;changes.value++;until {owner.state.readFailure!=null};assertNull(owner.state.snapshot);assertFalse(owner.state.usable)
            fail=false;changes.value++;until {owner.state.usable};assertNull(owner.state.readFailure)
        } finally {owner.close()}
    }
    @Test fun detailControlsExposeRetentionAndStopOnBackgroundOrSourceLoss() {
        var state by mutableStateOf(ResourceDetailState(key,available=true,snapshot=snapshot()));var active by mutableStateOf(true);var writes=0
        compose.setContent {MaterialTheme {ResourceDetailScreen(state,active,{writes++;state=state.copy(snapshot=snapshot(it))},{},{},{},{})}}
        compose.onNodeWithTag("resource-retain").performScrollTo().performClick();compose.onNodeWithText("解除保留本机").assertIsDisplayed();compose.onNodeWithText("已保留，等待下载").assertIsDisplayed()
        compose.runOnIdle {active=false};compose.onNodeWithTag("resource-retain").assertIsNotEnabled();compose.onNodeWithTag("resource-open").assertIsNotEnabled()
        compose.runOnIdle {active=true;state=state.copy(snapshot=snapshot().copy(variants=persistentListOf()))}
        compose.onNodeWithTag("resource-retain").assertDoesNotExist();compose.onNodeWithTag("resource-open").assertIsNotEnabled()
        compose.runOnIdle {active=true;state=state.copy(snapshot=null,feedback="资源或原消息当前不可访问")}
        compose.onNodeWithTag("resource-retain").assertDoesNotExist();compose.onNodeWithTag("resource-open").assertDoesNotExist();compose.runOnIdle {assertEquals(1,writes)}
    }
    @Test fun sameQueryRefreshKeepsMetadataStableButNeverBypassesMutationAuthority()=runBlocking {
        val changes=MutableStateFlow(0L);val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        var visible=true;var refreshing=false;var attempts=0
        val owner=ResourceDetailController(key,this,changes,{_,_->if(refreshing) {entered.complete(Unit);release.await()};if(visible) snapshot() else null},
            {_,_->attempts++;check(visible) {"revoked"}},{})
        try {
            owner.foreground(true);until {owner.state.usable};refreshing=true;changes.value++;entered.await()
            assertEquals(snapshot(),owner.state.snapshot);assertTrue(owner.state.usable)
            visible=false;owner.setRetained(true);until {attempts==1 && !owner.state.working};release.complete(Unit)
            until {owner.state.readFailure!=null};assertNull(owner.state.snapshot);assertFalse(owner.state.usable)
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun libraryShowsBoundedRowsAndRestoresFilterChoices() {
        val restoration=StateRestorationTester(compose);var selected:ResourceKey?=null
        var state by mutableStateOf(ResourceLibraryState(available=true,entries=page.entries))
        restoration.setContent {MaterialTheme {ResourceLibraryScreen(state,true,false,{text,kind,retained->state=state.copy(search=text,category=kind,retainedOnly=retained)},{},{},{selected=it})}}
        compose.onNodeWithTag("resource-library-retained").performClick();compose.onNodeWithTag("resource-library-search").performTextInput("项目")
        restoration.emulateSavedInstanceStateRestore();compose.onNodeWithTag("resource-library-search").assertTextContains("项目");compose.onNodeWithTag("resource-library-retained").assertIsSelected()
        compose.onNodeWithTag("resource-entry-${key.media}").performClick();compose.runOnIdle {assertEquals(key,selected)}
    }
    @Test fun resourceDetailRestoresInSharedStackAndReturnsToTheSameLibrary() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("resources",model)}
        val session=SessionUi.SignedIn(UserId(id()))
        val state=AppState(session=session,resourceLibrary=ResourceLibraryState(available=true,entries=page.entries),resourceDetail=ResourceDetailState(key,available=true,snapshot=snapshot()))
        val restoration=StateRestorationTester(compose);lateinit var stack:NavBackStack<NavKey>
        restoration.setContent {stack=rememberNavBackStack(Route.Home,Route.Page(PageKind.Resources));MaterialTheme {SignedIn(state,session,model,stack)}}
        try {
            compose.onNodeWithTag("resource-entry-${key.media}").performClick();compose.onNodeWithTag("resource-detail").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restoration.emulateSavedInstanceStateRestore();compose.runOnIdle {assertEquals(Route.ResourceDetail(room.value,key.media),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-library-list").assertIsDisplayed()
            compose.runOnIdle {assertEquals(Route.Page(PageKind.Resources),stack.last())}
        } finally {compose.runOnUiThread {owners.clear()}}
    }
    @Test fun postDownloadRefreshKeepsMetadataAndAtomicallyDisablesStaleActions()=runBlocking<Unit> {
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var enqueued=false
        val emitted=mutableListOf<ResourceDetailState>()
        val owner=ResourceDetailController(key,this,MutableStateFlow(0L),{_,_->if(enqueued) {entered.complete(Unit);finish.await();null} else snapshot()},
            {_,_->},{emitted.add(it)},enqueue={_,_->enqueued=true;"download"})
        try {
            owner.foreground(true);until {owner.state.usable};owner.download();entered.await()
            assertEquals(snapshot(),owner.state.snapshot);assertTrue(owner.state.loading);assertFalse(owner.state.working);assertFalse(owner.state.usable)
            assertTrue(emitted.filter {it.queuedDownload=="download"}.none {it.usable})
            finish.complete(Unit);until {owner.state.readFailure!=null};assertNull(owner.state.snapshot);assertFalse(owner.state.usable)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun accountDownloadNavigationSurvivesResourceRefreshAndSourceLoss() {
        var state by mutableStateOf(ResourceDetailState(key,available=true,snapshot=snapshot()));var active by mutableStateOf(true);var navigations=0
        compose.setContent {MaterialTheme {ResourceDetailScreen(state,active,{},{},{},{},{},downloads={navigations++})}}
        compose.runOnIdle {state=state.copy(snapshot=null,loading=true,queuedDownload="download")}
        compose.onNodeWithTag("resource-download-tasks").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle {state=state.copy(loading=false,readFailure="资源不可用")}
        compose.onNodeWithTag("resource-download-tasks").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle {active=false;assertEquals(2,navigations)};compose.onNodeWithTag("resource-download-tasks").assertIsNotEnabled()
    }

}
