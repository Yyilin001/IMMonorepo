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

class ResourceBusinessOwnerUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun status():ProfileIntentStatus {
        val actor=UserId(id());val source=ProfileAvatarImport(id(),ResourceImportRequest(id(),ResourceImportSource.Message(RoomId(id()),MessageId(id()),id()),ResourceUsage.UserAvatar,id()))
        val intent=ProfileIntent(id(),actor,id(),1,86401000,name="新昵称",serverImport=source)
        return ProfileIntentStatus(intent,null,ProfileIntentPhase.PreparingAvatar,false)
    }
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun pageReadFailureAndLateOpenCannotExposeOldOwnerNavigation()=runBlocking<Unit> {
        val transfer=ResourceTransferId(ResourceTransferKind.Upload,id());val owner=ResourceBusinessOwner.Profile(id());val changes=MutableStateFlow(0L)
        val gate=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();var fail=false
        val controller=ResourceBusinessController(ResourceBusinessSelection(transfer),this,changes,
            {if(fail) error("read") else ResourceBusinessOwnerPage(persistentListOf(ResourceBusinessOwnerEntry(owner,1)))},
            {entered.complete(Unit);withContext(NonCancellable) {gate.await()};true},{null},{null},{error("no plan")},{},{})
        try {
            controller.foreground(true);until {controller.state.available};controller.open(owner);entered.await();controller.foreground(false);gate.complete(Unit);yield()
            assertNull(controller.state.opened);assertFalse(controller.state.available)
            controller.foreground(true);until {controller.state.available};fail=true;changes.value++;until {!controller.state.available && !controller.state.loading}
            assertTrue(controller.state.page.entries.isEmpty());controller.open(owner);assertNull(controller.state.opened)
        } finally {gate.complete(Unit);controller.close()}
    }
    @Test fun profileChangeInvalidatesReviewAndFailedCommitRequiresANewPlan()=runBlocking<Unit> {
        var value=status();val transfer=ResourceTransferId(ResourceTransferKind.ServerImport,value.intent.serverImport!!.id);val changes=MutableStateFlow(0L);var commits=0
        val controller=ResourceBusinessController(ResourceBusinessSelection(transfer,value.intent.id),this,changes,{error("no list")},{true},{value},{null},
            {ResourceProfileDispositionPlan(id(),transfer,value.intent.id,ResourceProfileDispositionEffect.WithdrawUnsubmittedChange)},{commits++;throw ResourceTransferActionUnavailable()},{})
        try {
            controller.foreground(true);until {controller.state.available};controller.review();until {controller.state.disposition!=null && !controller.state.working}
            value=value.copy(intent=value.intent.copy(preparation=ProfilePreparation.NeedsAttention),phase=ProfileIntentPhase.NeedsAttention);changes.value++
            until {controller.state.disposition==null};controller.confirm();assertEquals(0,commits)
            controller.review();until {controller.state.disposition!=null && !controller.state.working};controller.confirm();until {!controller.state.working}
            assertNull(controller.state.disposition);assertEquals(1,commits);assertFalse(controller.state.feedback!!.startsWith("已放弃"));controller.confirm();assertEquals(1,commits)
        } finally {controller.close()}
    }
    @Test fun wrongProfileOrMismatchedDispositionCannotProduceAConfirmation()=runBlocking<Unit> {
        val value=status();val transfer=ResourceTransferId(ResourceTransferKind.ServerImport,value.intent.serverImport!!.id);var wrongRead=true
        val controller=ResourceBusinessController(ResourceBusinessSelection(transfer,value.intent.id),this,MutableStateFlow(0L),{error("no list")},{true},
            {if(wrongRead) value.copy(intent=value.intent.copy(id=id())) else value},{null},
            {ResourceProfileDispositionPlan(id(),transfer,id(),ResourceProfileDispositionEffect.WithdrawUnsubmittedChange)},{error("must not commit")},{})
        try {
            controller.foreground(true);until {!controller.state.loading};assertFalse(controller.state.available);assertNull(controller.state.profile)
            wrongRead=false;controller.reload();until {controller.state.available};controller.review();until {!controller.state.working};assertNull(controller.state.disposition)
        } finally {controller.close()}
    }
    @Test fun actualProfileScreenReviewsWholeChangeAndOnlyExplicitConfirmationCommits() {
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val value=status();val key=ResourceTransferId(ResourceTransferKind.ServerImport,value.intent.serverImport!!.id)
        val selection=ResourceBusinessSelection(key,value.intent.id);val state=mutableStateOf(ResourceBusinessState(selection));var current:ProfileIntentStatus?=value;var commits=0
        lateinit var controller:ResourceBusinessController
        compose.runOnIdle {controller=ResourceBusinessController(selection,scope,MutableStateFlow(0L),{error("no list")},{true},{current},{null},
            {ResourceProfileDispositionPlan(id(),key,value.intent.id,ResourceProfileDispositionEffect.WithdrawUnsubmittedChange)},{commits++;current=null},{state.value=it});controller.foreground(true)}
        try {
            compose.setContent {MaterialTheme {ResourceBusinessScreen(state.value,true,false,controller::page,controller::reload,controller::open,controller::resume,controller::review,controller::confirm,controller::dismiss,controller::opened,{})}}
            compose.waitUntil {state.value.available};compose.onNodeWithTag("resource-profile-dispose").performClick();compose.waitUntil {state.value.disposition!=null && !state.value.working}
            compose.onNodeWithText("将整体放弃本次昵称与头像更改",substring=true).assertIsDisplayed();assertEquals(0,commits)
            if(InstrumentationRegistry.getArguments().getString("captureBusinessUI")=="true") {
                val bitmap=compose.onNode(isDialog()).captureToImage().asAndroidBitmap()
                java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"business-profile-confirmation.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
            }
            compose.onNodeWithText("继续保留").performClick();assertEquals(0,commits)
            compose.onNodeWithTag("resource-profile-dispose").performClick();compose.waitUntil {state.value.disposition!=null && !state.value.working};compose.onNodeWithTag("resource-profile-confirm").performClick()
            compose.waitUntil {commits==1 && !state.value.working};compose.onNodeWithText("这次更改已处理或不再持有此资源").assertIsDisplayed()
        } finally {compose.runOnIdle {controller.close()};scope.cancel()}
    }
    @Test fun focusedGroupScreenShowsOnlyItsOperationAndHidesUnrelatedEditing() {
        val actor=UserId(id());val device=DeviceId(id());val room=RoomId(id());val upload=id()
        fun intent()=GroupAvatarIntent(actor,device,GroupAvatarCommand(id(),room,0,GroupAvatarMutation.Set(id())),1,upload,id())
        val target=intent();val other=intent();val app=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(groupAvatarIntents=persistentListOf(target,other)))
        val editor=GroupAvatarEditorState(target.id,room,relatedAvailable=true)
        compose.setContent {MaterialTheme {GroupAvatarScreen(app,editor,true,null,{},{},{},{},{},{_,_->},focused=target.id)}}
        compose.onNodeWithTag("group-avatar-task-${target.id}").assertExists();compose.onNodeWithTag("group-avatar-task-${other.id}").assertDoesNotExist()
        compose.onNodeWithText("从相册选择").assertDoesNotExist();compose.onNodeWithText("从聊天图片选择").assertDoesNotExist()
    }
    @Test fun ownerRoutesRestoreTheirExactTransferAndReturnThroughTheSharedNav3Stack() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val model=AppViewModel(context.applicationContext as android.app.Application)
        val models=androidx.lifecycle.ViewModelStore().apply {put("business",model)}
        val value=status();val key=ResourceTransferId(ResourceTransferKind.ServerImport,value.intent.serverImport!!.id)
        val selection=ResourceBusinessSelection(key,value.intent.id);val session=SessionUi.SignedIn(value.intent.actor)
        val app=AppState(session=session,resourceBusiness=ResourceBusinessState(selection,profile=value,available=true))
        val destination=Route.ResourceProfileOwner(key.kind.name,key.value,value.intent.id)
        lateinit var stack:androidx.navigation3.runtime.NavBackStack<androidx.navigation3.runtime.NavKey>
        val restoration=androidx.compose.ui.test.junit4.StateRestorationTester(compose)
        restoration.setContent {stack=androidx.navigation3.runtime.rememberNavBackStack(Route.Home,Route.Page(PageKind.Transfers),Route.ResourceOwners(key.kind.name,key.value),destination);MaterialTheme {SignedIn(app,session,model,stack)}}
        try {
            compose.onNodeWithTag("resource-profile-status").assertIsDisplayed();restoration.emulateSavedInstanceStateRestore()
            compose.runOnIdle {assertEquals(destination,stack.last())};compose.onNodeWithTag("resource-profile-dispose").assertExists()
            compose.onNodeWithContentDescription("返回").performClick();compose.runOnIdle {assertEquals(Route.ResourceOwners(key.kind.name,key.value),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-transfers").assertIsDisplayed()
        } finally {compose.runOnUiThread {models.clear()}}
    }
}
