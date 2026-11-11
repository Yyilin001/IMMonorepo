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

class ResourceDownloadUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id());private val key=ResourceKey(ResourceHome.Room(room),id())
    private val descriptor=ResourceDescriptor(key,1,"下载说明.txt","text/plain",8,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private val source=MessageResourceSource(room,MessageId(id()),0,1)
    private val job=ResourceDownloadWork(id(),descriptor,MediaMessageLocation(room,source.message),0)
    private fun detail()=ResourceDetailSnapshot(descriptor,persistentListOf(ResourceVariantSnapshot(ResourceVariantDescriptor(ResourceVariantKey(key),descriptor.checksum!!,8),false,false)),ResourceSourcePage(persistentListOf(source),null))
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun repeatedDownloadClickSavesOneIntentAndLateCommitDoesNotReviveClosedDetails()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var writes=0
        val owner=ResourceDetailController(key,this,MutableStateFlow(0L),{_,_->detail()},{_,_->},{},enqueue={_,_->entered.complete(Unit);withContext(NonCancellable) {release.await();writes++;job.id}})
        try {
            owner.foreground(true);until {owner.state.usable};owner.download();owner.download();entered.await();owner.close();release.complete(Unit);until {writes==1}
            assertNull(owner.state.queuedDownload);assertFalse(owner.state.available)
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun cancellationAndPauseCannotBeResumedUntilTheirClaimDrains() {
        val running=job.copy(phase=ResourceDownloadPhase.Running,owner=id(),claim=id(),attempts=1)
        val pausing=ResourceDownloadSnapshot(running.copy(control=ResourceDownloadControl.Pause,requested=false),true)
        assertFalse(downloadAllows(pausing,ResourceDownloadControl.Run));assertTrue(downloadAllows(pausing,ResourceDownloadControl.Cancel))
        assertEquals("正在暂停，等待传输结束",downloadStatus(pausing.work))
        assertTrue(downloadAllows(pausing.copy(work=pausing.work.copy(phase=ResourceDownloadPhase.Pending,owner=null,claim=null)),ResourceDownloadControl.Run))
        val cancelling=pausing.copy(work=pausing.work.copy(control=ResourceDownloadControl.Cancel))
        assertTrue(ResourceDownloadControl.entries.none {downloadAllows(cancelling,it)})
        val delegated=job.copy(backgroundPending=true,control=ResourceDownloadControl.Pause,requested=false)
        assertFalse(downloadAllows(ResourceDownloadSnapshot(delegated,true),ResourceDownloadControl.Run))
        assertEquals("正在暂停，等待传输结束",downloadStatus(delegated))
        assertEquals("等待系统传输及文件校验",downloadStatus(job.copy(backgroundPending=true)))
    }
    @Test fun closedTaskPageIgnoresLateControlResultsAndRevocationStillAllowsCancellation()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var writes=0
        val owner=ResourceDownloadsController(this,MutableStateFlow(0L),{persistentListOf(ResourceDownloadSnapshot(job,false))},{_,action->assertEquals(ResourceDownloadControl.Cancel,action);entered.complete(Unit);withContext(NonCancellable) {release.await();writes++}},{})
        try {
            owner.foreground(true);until {!owner.state.loading};owner.act(job.id,ResourceDownloadControl.Pause);assertEquals(0,writes)
            owner.act(job.id,ResourceDownloadControl.Cancel);entered.await();owner.foreground(false);release.complete(Unit);until {writes==1}
            assertFalse(owner.state.available);assertNull(owner.state.working);assertTrue(owner.state.entries.isEmpty())
        } finally {release.complete(Unit);owner.close()}
    }
    @Test fun revokedTaskHidesFilenameAndNavigationButKeepsStopControl() {
        var state by mutableStateOf(ResourceDownloadsState(available=true,entries=persistentListOf(ResourceDownloadSnapshot(job,true))));var cancellations=0
        compose.setContent {MaterialTheme {ResourceDownloadsScreen(state,true,false,{_,action->if(action==ResourceDownloadControl.Cancel) cancellations++},{},{})}}
        compose.onNodeWithText("下载说明.txt").assertIsDisplayed();compose.onNodeWithText("查看资源").assertIsDisplayed()
        compose.runOnIdle {state=state.copy(entries=persistentListOf(ResourceDownloadSnapshot(job,false)))}
        compose.onNodeWithText("下载说明.txt").assertDoesNotExist();compose.onNodeWithText("查看资源").assertDoesNotExist()
        compose.onNodeWithTag("download-Cancel-${job.id}").performClick();compose.runOnIdle {assertEquals(1,cancellations)}
    }
    @Test fun taskRouteRestoresAndReturnsToItsResourceDetail() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("download",model)}
        val session=SessionUi.SignedIn(UserId(id()));val state=AppState(session=session,resourceDetail=ResourceDetailState(key,available=true,snapshot=detail()),resourceDownloads=ResourceDownloadsState(available=true,entries=persistentListOf(ResourceDownloadSnapshot(job,true))))
        val restoration=StateRestorationTester(compose);lateinit var stack:NavBackStack<NavKey>
        restoration.setContent {stack=rememberNavBackStack(Route.Home,Route.ResourceDetail(room.value,key.media));MaterialTheme {SignedIn(state,session,model,stack)}}
        try {
            compose.onNodeWithTag("resource-download").assertIsEnabled();compose.onNodeWithTag("resource-download-tasks").performScrollTo().performClick()
            compose.onNodeWithTag("resource-downloads").assertIsDisplayed();restoration.emulateSavedInstanceStateRestore();compose.runOnIdle {assertEquals(Route.Page(PageKind.Downloads),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-detail").assertIsDisplayed()
        } finally {compose.runOnUiThread {owners.clear()}}
    }
    @Test fun networkControlsPublishImmutableValuesAndDisableDuringSaveOrDemo() {
        var state by mutableStateOf(ResourceDownloadsState(available=true,network=ResourceDownloadNetworkPreferences()))
        var demo by mutableStateOf(false);var changes=0
        compose.setContent {MaterialTheme {ResourceDownloadsScreen(state,true,demo,{_,_->},{},{},network={value->
            changes++;state=state.copy(network=value)
        })}}
        compose.onNodeWithTag("download-cellular").assertIsOn().performClick().assertIsOff()
        compose.onNodeWithTag("download-constrained").assertIsOff().performClick().assertIsOn()
        compose.runOnIdle {assertEquals(ResourceDownloadNetworkPreferences(false,true),state.network);assertEquals(2,changes);state=state.copy(working="network")}
        compose.onNodeWithTag("download-cellular").assertIsNotEnabled()
        compose.runOnIdle {state=state.copy(working=null);demo=true}
        compose.onNodeWithTag("download-cellular").assertIsNotEnabled()
    }
    @Test fun lateNetworkSaveCannotRestoreAnInactivePagesState()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var saved=ResourceDownloadNetworkPreferences()
        val owner=ResourceDownloadsController(this,MutableStateFlow(0L),{persistentListOf()},{_,_->},{},
            readNetwork={saved},writeNetwork={value->entered.complete(Unit);withContext(NonCancellable) {release.await();saved=value}})
        try {
            owner.foreground(true);until {owner.state.network!=null && !owner.state.loading}
            owner.network(ResourceDownloadNetworkPreferences(false,true));entered.await();owner.foreground(false)
            release.complete(Unit);until {!saved.allowsCellular}
            assertFalse(owner.state.available);assertNull(owner.state.network);assertNull(owner.state.working)
            owner.foreground(true);until {owner.state.network==saved && !owner.state.loading}
        } finally {release.complete(Unit);owner.close()}
    }

    @Test fun automaticCategoryAndSizeSelectionsPreserveIndependentNetworkChoices() {
        var state by mutableStateOf(ResourceDownloadsState(available=true,network=ResourceDownloadNetworkPreferences(false,true)))
        compose.setContent {MaterialTheme {ResourceDownloadsScreen(state,true,false,{_,_->},{},{},network={value->state=state.copy(network=value)})}}
        compose.onNodeWithTag("download-auto-Image").performScrollTo().assertIsNotSelected().performClick().assertIsSelected()
        compose.onNodeWithTag("download-auto-File").performScrollTo().performClick()
        compose.onNodeWithTag("download-auto-size").performScrollTo().performClick();compose.onNodeWithTag("download-auto-size-50").performClick()
        compose.runOnIdle {
            assertEquals(ResourceDownloadNetworkPreferences(false,true,ResourceAutomaticDownloadPolicy(persistentSetOf(ResourceCategory.Image,ResourceCategory.File),50L*1024*1024)),state.network)
        }
        compose.onNodeWithTag("download-auto-Image").performScrollTo().performClick().assertIsNotSelected()
        compose.runOnIdle {assertEquals(persistentSetOf(ResourceCategory.File),state.network!!.automaticDownloads.categories)}
    }

}
