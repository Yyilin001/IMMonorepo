package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class AvatarResourcePickerUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val id="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val profile=ProfileView(actor,PublicIdentity(actor,PublicHandle("avatar_resource"),"本人",AccountKind.Regular),null,ProfileState.Active,1,1)
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id),1,"海边照片.png","image/png",1024,ResourceChecksum("a".repeat(64)),ResourceState.Ready,32,32)
    private val selection=AvatarResourceSelection(descriptor,MessageResourceSource(room,MessageId(actor.value),0,1))
    private fun app()=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(ownProfile=profile))
    private fun picker()=AvatarResourcePickerState("picker",available=true,entries=persistentListOf(ResourceCatalogEntry(descriptor,1000,1)),next=ResourceCatalogCursor(1000,descriptor.key))
    private fun capture(name: String) {
        if(InstrumentationRegistry.getArguments().getString("captureAvatarResources")=="true") {
            compose.waitForIdle()
            val instrumentation=InstrumentationRegistry.getInstrumentation()
            val bitmap=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            try { instrumentation.targetContext.openFileOutput(name,0).use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } }
            finally { bitmap.recycle() }
        }
    }
    @Test fun groupConfirmationRequiresFreshAuthorityAndBlocksPendingOrRevokedTarget() {
        var state by mutableStateOf(picker().copy(targetRoom=room));var app by mutableStateOf(app());var saves=0
        compose.setContent { MaterialTheme { AvatarResourcePickerScreen(app,state,true,{},{},{},{},{ state=state.copy(selected=selection) },
            {state=state.copy(groupBaseline=GroupAvatarPickerBaseline(room,3,System.nanoTime()+60000000000))},{saves++},{state=state.copy(selected=null)}) } }
        compose.onNodeWithText("选择群头像").assertIsDisplayed();compose.onNodeWithTag("avatar-resource-$id").performClick()
        compose.onNodeWithText("使用这张聊天图片作为群头像？").assertIsDisplayed();compose.onNodeWithText("确认使用").assertIsNotEnabled()
        compose.onNodeWithText("刷新后确认").performClick();compose.onNodeWithText("确认使用").assertIsEnabled()
        capture("group-avatar-resources-confirm.png")
        compose.runOnIdle {state=state.copy(groupBaseline=state.groupBaseline!!.copy(deadlineNanos=System.nanoTime()-1))}
        compose.onNodeWithText("确认使用").assertIsNotEnabled();compose.onNodeWithText("刷新后确认").performClick()
        compose.onNodeWithText("确认使用").performClick();compose.runOnIdle {assertEquals(1,saves)}
        compose.runOnIdle {
            val intent=GroupAvatarIntent(actor,DeviceId(actor.value),GroupAvatarCommand(id,room,3,GroupAvatarMutation.Remove),0)
            app=app.copy(snapshot=app.snapshot.copy(groupAvatarIntents=persistentListOf(intent)))
        }
        compose.onNodeWithText("确认使用").assertIsNotEnabled();compose.onNodeWithText("取消").performClick()
        compose.onNodeWithTag("avatar-resource-$id").assertIsNotEnabled()
        compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(groupAvatarIntents=persistentListOf(),revokedRooms=kotlinx.collections.immutable.persistentSetOf(room)))}
        compose.onNodeWithTag("avatar-resource-$id").assertIsNotEnabled()
    }
    @Test fun groupResourceRouteRestoresOnlyTargetIdsAndReturnsToItsGroupEditor() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val model=AppViewModel(context.applicationContext as android.app.Application)
        val owners=androidx.lifecycle.ViewModelStore().apply {put("group-picker",model)}
        val session=SessionUi.SignedIn(actor)
        val state=app().copy(groupAvatarEditor=GroupAvatarEditorState("group",room),avatarResources=picker().copy(id="group",targetRoom=room))
        lateinit var stack:androidx.navigation3.runtime.NavBackStack<androidx.navigation3.runtime.NavKey>
        val restore=StateRestorationTester(compose)
        try {
            restore.setContent {stack=androidx.navigation3.runtime.rememberNavBackStack(Route.Home,Route.GroupAvatar(room.value,"group"),Route.AvatarResources("group",room.value));MaterialTheme {SignedIn(state,session,model,stack)}}
            compose.onNodeWithText("选择群头像").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("选择群头像").assertIsDisplayed()
            compose.runOnIdle {assertEquals(Route.AvatarResources("group",room.value),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("group-avatar-page").assertExists()
            compose.runOnIdle {assertEquals(Route.GroupAvatar(room.value,"group"),stack.last())}
        } finally {compose.runOnUiThread {owners.clear()}}
    }
    @Test fun explicitConfirmationCanRefreshStaleBaselineInsideTheDialog() {
        var state by mutableStateOf(picker());var app by mutableStateOf(app());var saves=0
        compose.setContent { MaterialTheme { AvatarResourcePickerScreen(app,state,true,{},{},{},{},{ state=state.copy(selected=selection) },{ state=state.copy(baseline=app.snapshot.ownProfile) },{ saves++ },{ state=state.copy(selected=null) }) } }
        compose.onNodeWithTag("avatar-resource-$id").assertIsDisplayed()
        capture("avatar-resources.png")
        compose.onNodeWithTag("avatar-resource-$id").performClick()
        compose.runOnIdle { assertEquals(0,saves) }
        compose.onNodeWithText("确认使用").assertIsNotEnabled();compose.onNodeWithText("刷新后确认").performClick()
        compose.onNodeWithText("确认使用").assertIsEnabled()
        capture("avatar-resources-confirm.png")
        compose.runOnIdle { app=app.copy(snapshot=app.snapshot.copy(ownProfile=profile.copy(revision=2))) }
        compose.onNodeWithText("确认使用").assertIsNotEnabled();compose.onNodeWithText("刷新后确认").performClick()
        compose.onNodeWithText("确认使用").performClick();compose.runOnIdle { assertEquals(1,saves) }
    }
    @Test fun leavingPageDismissesConfirmationAndPendingChangesDisableEntry() {
        var state by mutableStateOf(picker().copy(baseline=profile));var app by mutableStateOf(app());var active by mutableStateOf(true)
        compose.setContent { MaterialTheme { AvatarResourcePickerScreen(app,state,active,{},{},{},{},{ state=state.copy(selected=selection) },{},{},{ state=state.copy(selected=null) }) } }
        compose.onNodeWithTag("avatar-resource-$id").performClick();compose.onNodeWithText("确认使用").assertIsDisplayed()
        compose.runOnIdle { active=false };compose.onNodeWithText("确认使用").assertDoesNotExist();compose.onNodeWithTag("avatar-resource-$id").assertIsNotEnabled()
        compose.runOnIdle {
            assertNull(state.selected);active=true
            val intent=ProfileIntent(id,actor,room.value,1,1800000000000,name="待确认名称")
            app=app.copy(snapshot=app.snapshot.copy(profileIntents=persistentListOf(ProfileIntentStatus(intent,null,ProfileIntentPhase.WaitingToSubmit,false))))
        }
        compose.onNodeWithTag("avatar-resource-$id").assertIsNotEnabled();compose.onNodeWithText("请先处理尚未确认的资料修改。").assertIsDisplayed()
    }
    @Test fun searchRestoresAndPaginationUsesExplicitActions() {
        val restoration=StateRestorationTester(compose);var text="";var next=0;var previous=0
        restoration.setContent { MaterialTheme { AvatarResourcePickerScreen(app(),picker(),true,{ text=it },{ next++ },{ previous++ },{},{},{},{},{}) } }
        compose.onNodeWithTag("avatar-resources-search").performTextInput("海边")
        compose.runOnIdle { assertEquals("海边",text) };restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("avatar-resources-search").assertTextContains("海边")
        compose.onNodeWithText("上一页").assertIsNotEnabled();compose.onNodeWithText("下一页").performClick()
        compose.runOnIdle { assertEquals(1,next);assertEquals(0,previous) }
    }
    @Test fun demoHasNoImportActionsAndAvatarEditorDispatchesRealAccountEntry() {
        var demo by mutableStateOf(true);var editor by mutableStateOf(false);var opened=0
        compose.setContent { MaterialTheme {
            val state=app().copy(session=SessionUi.SignedIn(actor,demo=demo))
            if(editor) AvatarEditorScreen(state,AvatarEditorState("editor",baseline=profile),true,{},{},{},{},{},{},{},chatImages={ opened++ })
            else AvatarResourcePickerScreen(state,picker(),true,{},{},{},{},{},{},{},{})
        } }
        compose.onNodeWithText("聊天图片选择需要登录真实账号。").assertIsDisplayed();compose.onNodeWithTag("avatar-resource-$id").assertIsNotEnabled()
        compose.runOnIdle { editor=true };compose.onNodeWithText("从聊天图片选择").performScrollTo().assertIsNotEnabled()
        compose.runOnIdle { demo=false };compose.onNodeWithText("从聊天图片选择").performClick();compose.runOnIdle { assertEquals(1,opened) }
    }
}
