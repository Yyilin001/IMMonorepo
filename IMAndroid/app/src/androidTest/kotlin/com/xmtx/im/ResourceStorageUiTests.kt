package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ResourceStorageUiTests {
    @get:Rule val compose=createComposeRule()
    private val snapshot=ResourceStorageSnapshot(ResourceOriginalPolicy(),4096,8192,4096,0,4096,8192,4096,0,1,16384)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun quotaChangesAreSerializedAndDeferredCleanupIsVisible()=runBlocking {
        val gate=CompletableDeferred<Unit>();var writes=0
        val owner=ResourceStorageController(this,{snapshot},{bytes->writes++;gate.await();ResourceStoragePolicyResult(snapshot.copy(policy=snapshot.policy.copy(maximumCacheBytes=bytes)),true)},{})
        try {
            owner.foreground(true);until {!owner.state.working};owner.cacheLimit(1);owner.cacheLimit(2);until {writes==1};gate.complete(Unit);until {!owner.state.working}
            assertEquals(1L,owner.state.snapshot!!.policy.maximumCacheBytes);assertTrue(owner.state.feedback!!.contains("额度已保存"))
        } finally {gate.complete(Unit);owner.close()}
    }
    @Test fun backgroundAndCloseRejectLateReadsAndWrites()=runBlocking {
        val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>()
        val owner=ResourceStorageController(this,{entered.complete(Unit);withContext(NonCancellable) {gate.await()};snapshot},{error("no write")},{})
        try {owner.foreground(true);entered.await();owner.foreground(false);gate.complete(Unit);delay(50);assertNull(owner.state.snapshot);assertFalse(owner.state.available)} finally {gate.complete(Unit);owner.close()}
        val writing=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();var saved=false
        val second=ResourceStorageController(this,{snapshot},{writing.complete(Unit);withContext(NonCancellable) {finish.await();saved=true};ResourceStoragePolicyResult(snapshot,false)},{})
        try {second.foreground(true);until {!second.state.working};second.cacheLimit(1);writing.await();second.close();finish.complete(Unit);until {saved};assertEquals(ResourceStorageState(),second.state)} finally {finish.complete(Unit);second.close()}
    }
    @Test fun failedWriteClearsStaleQuotaAndRefreshReadsActualSavedPolicy()=runBlocking {
        var current=snapshot;val owner=ResourceStorageController(this,{current},{bytes->current=snapshot.copy(policy=snapshot.policy.copy(maximumCacheBytes=bytes));error("result lost")},{})
        try {
            owner.foreground(true);until {!owner.state.working};owner.cacheLimit(100);until {!owner.state.working};assertNull(owner.state.snapshot)
            owner.refresh();until {!owner.state.working};assertEquals(100L,owner.state.snapshot!!.policy.maximumCacheBytes)
        } finally {owner.close()}
    }
    @Test fun cacheMenuUsesExplicitByteValuesAndScreenShowsUsage() {
        var selected=0L
        compose.setContent {MaterialTheme {ResourceStorageScreen(ResourceStorageState(true,snapshot=snapshot),true,false,{}, {selected=it},{},{})}}
        compose.onNodeWithText("保留本机").assertIsDisplayed();compose.onNodeWithTag("storage-cache-limit").performScrollTo().performClick()
        compose.onNodeWithTag("storage-cache-256").performClick();compose.runOnIdle {assertEquals(256L*1024*1024,selected)}
    }
    @Test fun storageRouteRestoresAndReturnsToResourceLibrary() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("storage",model)}
        val session=SessionUi.SignedIn(UserId(UUID.randomUUID().toString()));val state=AppState(session=session,resourceLibrary=ResourceLibraryState(available=true),resourceStorage=ResourceStorageState(true,snapshot=snapshot))
        val restoration=StateRestorationTester(compose);lateinit var stack:NavBackStack<NavKey>
        restoration.setContent {stack=rememberNavBackStack(Route.Home,Route.Page(PageKind.Resources));MaterialTheme {SignedIn(state,session,model,stack)}}
        try {
            compose.onNodeWithTag("resource-storage-open").performClick();compose.onNodeWithTag("resource-storage").assertIsDisplayed();restoration.emulateSavedInstanceStateRestore()
            compose.runOnIdle {assertEquals(Route.Page(PageKind.Storage),stack.last())};compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-library-search").assertIsDisplayed()
        } finally {compose.runOnUiThread {owners.clear()}}
    }
}
