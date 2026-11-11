package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class DraftImageUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id());private val asset=id();private val selection=DraftImageSelection(room,asset)
    private val attachment=SendAttachment(id(),asset,"海边.jpg","image/jpeg",1200)
    @Test fun localImageZoomAndImmediateRouteAndForegroundGates() {
        val photo=runBlocking { draftImageTestPhoto() };var active by mutableStateOf(true);var state by mutableStateOf(DraftImageState(selection,true,attachment,photo))
        compose.setContent { MaterialTheme { DraftImageScreen(state,selection,active,{}) } }
        compose.waitUntil(5000) { compose.onAllNodesWithTag("draft-image-pixels").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("缩小").assertIsNotEnabled();repeat(3) { compose.onNodeWithText("放大").performClick() };compose.onNodeWithText("放大").assertIsNotEnabled()
        compose.onNodeWithText("重置").performClick();compose.onNodeWithText("缩小").assertIsNotEnabled()
        compose.runOnIdle { active=false };compose.onNodeWithTag("draft-image-pixels").assertDoesNotExist()
        compose.runOnIdle { active=true;state=state.copy(selection=DraftImageSelection(room,id())) };compose.onNodeWithTag("draft-image-pixels").assertDoesNotExist()
        compose.runOnIdle { state=state.copy(selection=selection,available=false) };compose.onNodeWithTag("draft-image-pixels").assertDoesNotExist()
    }
    @Test fun sharedNav3StackRestoresOnlySelectionIdsAndReturnsToChatDraft() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply { put("draft",model) }
        val photo=runBlocking { draftImageTestPhoto() };val app=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"本地图片群",kind=RoomKind.Group))),draftImage=DraftImageState(selection,true,attachment,photo))
        lateinit var stack:NavBackStack<NavKey>;val restore=StateRestorationTester(compose)
        try {
            restore.setContent { stack=rememberNavBackStack(Route.Home);MaterialTheme { SignedIn(app,SessionUi.SignedIn(actor),model,stack) } }
            compose.onNodeWithText("本地图片群").performClick();compose.onNodeWithText("发送消息…").performTextInput("查看后继续编辑")
            compose.runOnIdle { stack.add(Route.DraftImage(room.value,asset)) }
            compose.waitUntil(5000) { compose.onAllNodesWithTag("draft-image-pixels").fetchSemanticsNodes().isNotEmpty() };compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.waitUntil(5000) { compose.onAllNodesWithTag("draft-image-pixels").fetchSemanticsNodes().isNotEmpty() }
            val encoded=Json.encodeToString<Route>(Route.DraftImage(room.value,asset));assertFalse(encoded.contains("海边"));assertFalse(encoded.contains("photo"));assertTrue(encoded.contains(asset))
            if(InstrumentationRegistry.getArguments().getString("captureDraftImage")=="true") {
                compose.waitForIdle();val image=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                try { context.openFileOutput("draft-image-viewer.png",0).use { image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } } finally { image.recycle() }
            }
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("查看后继续编辑").assertIsDisplayed()
        } finally { compose.runOnUiThread { owners.clear() } }
    }
    @Test fun draftAttachmentControlsOpenTheImageAndMoveItWithinBounds() {
        val second=attachment.copy(id=id(),asset=id());var state by mutableStateOf(ChatComposerState("editor",room,ConversationDraft(room,attachments=persistentListOf(attachment,second)),available=true,loading=false))
        var opened:String?=null;var moved:String?=null
        compose.setContent { MaterialTheme { ChatComposerBar(room,state,true,{_,_->},{false},{_,_->},{},{_,_->},{},{},openImage={opened=it},move={_,asset,offset->moved=asset;assertEquals(1,offset);state=state.copy(draft=state.draft!!.copy(attachments=persistentListOf(second,attachment),attachmentOrder=persistentListOf(second.id,attachment.id)))}) } }
        compose.onNodeWithTag("draft-move-back-$asset").assertIsNotEnabled();compose.onNodeWithTag("open-draft-image-$asset").performClick()
        compose.onNodeWithTag("draft-move-forward-$asset").performClick();compose.runOnIdle { assertEquals(asset,opened);assertEquals(asset,moved);assertEquals(second,state.attachments.first()) }
    }
}
