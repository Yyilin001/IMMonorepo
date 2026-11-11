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
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class UnavailableRetentionUiTests {
    @get:Rule val compose=createComposeRule()
    private val plan=ResourceUnavailableRetentionPlan(UUID.randomUUID().toString().uppercase(),2,false,System.currentTimeMillis()+60_000)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun previewDoesNotCommitAndDoubleConfirmationWritesOnlyOnce()=runBlocking {
        val gate=CompletableDeferred<Unit>();var writes=0
        val owner=UnavailableRetentionController(this,{plan},{writes++;gate.await();ResourceUnavailableRetentionResult(1,1)},{})
        try {
            owner.foreground(true);owner.prepare();until {owner.state.plan!=null};assertEquals(0,writes)
            owner.confirm();owner.confirm();until {writes==1};owner.dismiss();assertNotNull(owner.state.plan)
            gate.complete(Unit);until {!owner.state.working};assertNull(owner.state.plan);assertTrue(owner.state.feedback!!.contains("跳过 1 项"))
        } finally {gate.complete(Unit);owner.close()}
    }
    @Test fun backgroundAndClosedOwnersCannotPublishLatePreviewOrReleaseResults()=runBlocking {
        val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();var writes=0
        val owner=UnavailableRetentionController(this,{entered.complete(Unit);withContext(NonCancellable) {gate.await()};plan},{writes++;ResourceUnavailableRetentionResult(2,0)},{})
        try {
            owner.foreground(true);owner.prepare();entered.await();owner.foreground(false);gate.complete(Unit);delay(50)
            assertNull(owner.state.plan);assertFalse(owner.state.available);owner.confirm();assertEquals(0,writes)
        } finally {gate.complete(Unit);owner.close()}
        val enteredCommit=CompletableDeferred<Unit>();val done=CompletableDeferred<Unit>()
        val second=UnavailableRetentionController(this,{plan},{enteredCommit.complete(Unit);withContext(NonCancellable) {done.await();writes++};ResourceUnavailableRetentionResult(2,0)},{})
        try {
            second.foreground(true);second.prepare();until {second.state.plan!=null};second.confirm();enteredCommit.await();second.close();done.complete(Unit);until {writes==1}
            assertEquals(UnavailableRetentionState(),second.state)
        } finally {done.complete(Unit);second.close()}
    }
    @Test fun expiredPreviewFailureClearsConfirmationAndAllowsFreshPreview()=runBlocking {
        var calls=0;val owner=UnavailableRetentionController(this,{calls++;plan},{error("expired")},{})
        try {
            owner.foreground(true);owner.prepare();until {owner.state.plan!=null};owner.confirm();until {owner.state.feedback!=null}
            assertNull(owner.state.plan);assertFalse(owner.state.working);owner.prepare();until {calls==2 && owner.state.plan!=null}
            owner.dismiss();assertNull(owner.state.plan)
        } finally {owner.close()}
    }
    @Test fun confirmationDisplaysOnlyCountAndRequiresExplicitConfirmation() {
        var state by mutableStateOf(UnavailableRetentionState(available=true));var previews=0;var commits=0
        compose.setContent {MaterialTheme {UnavailableRetentionScreen(state,true,false,{previews++;state=state.copy(plan=plan)},{commits++},{state=state.copy(plan=null)})}}
        compose.onNodeWithTag("retention-release-preview").performClick();compose.runOnIdle {assertEquals(1,previews);assertEquals(0,commits)}
        compose.onNodeWithText("本次处理 2 项资源版本。预览有效期为 60 秒，执行时会重新检查。").assertIsDisplayed()
        compose.onNodeWithText("取消").performClick();compose.onNodeWithTag("retention-release-confirm").assertDoesNotExist()
        compose.onNodeWithTag("retention-release-preview").performClick();compose.onNodeWithTag("retention-release-confirm").performClick();compose.runOnIdle {assertEquals(1,commits)}
    }
    @Test fun resourceLibraryUsesSharedNav3RouteAndRestoresBackToLibrary() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("retention",model)}
        val session=SessionUi.SignedIn(UserId(UUID.randomUUID().toString()));val state=AppState(session=session,resourceLibrary=ResourceLibraryState(available=true),unavailableRetention=UnavailableRetentionState(available=true))
        val restoration=StateRestorationTester(compose);lateinit var stack:NavBackStack<NavKey>
        restoration.setContent {stack=rememberNavBackStack(Route.Home,Route.Page(PageKind.Resources));MaterialTheme {SignedIn(state,session,model,stack)}}
        try {
            compose.onNodeWithTag("resource-unavailable-retention").performClick();compose.onNodeWithTag("unavailable-retention").assertIsDisplayed()
            restoration.emulateSavedInstanceStateRestore();compose.runOnIdle {assertEquals(Route.Page(PageKind.UnavailableRetention),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-library-search").assertIsDisplayed()
        } finally {compose.runOnUiThread {owners.clear()}}
    }
}
