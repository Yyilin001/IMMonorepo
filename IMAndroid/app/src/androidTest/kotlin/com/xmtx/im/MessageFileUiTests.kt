package com.xmtx.im

import android.app.Application
import android.net.Uri
import android.content.Intent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MessageFileUiTests {
    @get:Rule val compose=createComposeRule()
    private val selection=fileTestSelection();private val read=fileTestRead();private val actor=UserId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private fun message()=Message(selection.location.message,selection.location.room,actor,"请查收文件",1000,media=MessageMedia(persistentListOf(selection.media),persistentListOf(MessageMediaPresentation(selection.media,MessageMediaKind.File,"text/plain",100,read.descriptor))))
    private fun app(message: Message=message())=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(selection.location.room,"文件测试群",kind=RoomKind.Group)),messages=persistentListOf(message)))
    @Test fun sharedNav3FileDetailRestoresIdsAndBackPreservesChatDraft() {
        val model=AppViewModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application);val owners=ViewModelStore().apply { put("files",model) };val restore=StateRestorationTester(compose);val sourceApp=installMediaNavigationSource(model,app())
        try {
            restore.setContent { MaterialTheme { SignedIn(sourceApp,SessionUi.SignedIn(actor),model) } }
            compose.onNodeWithText("文件测试群").performClick();compose.waitUntil(5000) {compose.onAllNodesWithTag("message-file-open-${selection.media}").fetchSemanticsNodes().isNotEmpty()};compose.onNodeWithText("发送消息…").performTextInput("返回后继续编辑")
            compose.onNodeWithTag("message-file-open-${selection.media}").performClick();compose.onNodeWithText("查看文件").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("查看文件").assertIsDisplayed();compose.waitUntil(5000) {compose.onAllNodesWithText("项目说明.txt").fetchSemanticsNodes().isNotEmpty()};compose.onNodeWithText("项目说明.txt").assertIsDisplayed()
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("返回后继续编辑").assertIsDisplayed()
            val route:Route=Route.MessageFile(selection.location.room.value,selection.location.message.value,selection.media);val encoded=Json.encodeToString(route)
            assertEquals(route,Json.decodeFromString<Route>(encoded));assertFalse(encoded.contains("content:"));assertFalse(encoded.contains("checksum"));assertFalse(encoded.contains("项目说明"))
        } finally { compose.runOnUiThread { owners.clear() };awaitMediaNavigationClosed(model) }
    }
    @Test fun projectionWithdrawalAndRevisionChangeDisableActionsImmediately() {
        var app by mutableStateOf(app());val state=MessageFileState(selection,true,read)
        compose.setContent { MaterialTheme { MessageFileScreen(app,state,selection,true,{null},{_,_->},{},{},{},openSources=rememberMessageSourceFixture(actor,app.snapshot.messages.single())) } }
        compose.onNodeWithText("保存到文件").assertIsEnabled()
        compose.runOnIdle { app=app(message().copy(revision=2)) };compose.onNodeWithText("保存到文件").assertIsNotEnabled()
        compose.runOnIdle { app=app(message().copy(withdrawn=true)) };compose.onNodeWithText("项目说明.txt").assertDoesNotExist();compose.onNodeWithText("保存到文件").assertIsNotEnabled()
    }
    @Test fun writingBlocksDuplicateSaveAndSuccessfulExportOffersReadOnlyOpen() {
        var state by mutableStateOf(MessageFileState(selection,true,read,FileSavePhase.Writing));var opened=0
        compose.setContent { MaterialTheme { MessageFileContent(read.descriptor,state,true,{}, {}, {opened++},present={}) } }
        compose.onNodeWithText("保存到文件").assertIsNotEnabled();compose.onNodeWithText("用其他应用打开").assertIsNotEnabled();compose.onNodeWithText("分享文件").assertIsNotEnabled();compose.onNodeWithText("打开已保存文件").assertDoesNotExist()
        compose.runOnIdle { state=state.copy(phase=FileSavePhase.Saved,savedUri="content://documents/saved",feedback="已保存到所选位置") }
        compose.onNodeWithText("打开已保存文件").performClick();assertEquals(1,opened)
        compose.onNodeWithText("用其他应用打开").assertIsEnabled();compose.onNodeWithText("分享文件").assertIsEnabled()
        val intent=savedDocumentIntent(Uri.parse(state.savedUri),read.descriptor.contentType)
        assertEquals(Intent.ACTION_VIEW,intent.action);assertEquals("text/plain",intent.type);assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION,intent.flags);assertEquals(intent.data,intent.clipData!!.getItemAt(0).uri)
        if(InstrumentationRegistry.getArguments().getString("captureFileExport")=="true") {
            compose.waitForIdle();val instrumentation=InstrumentationRegistry.getInstrumentation();val bitmap=instrumentation.uiAutomation.takeScreenshot()
            try { instrumentation.targetContext.openFileOutput("message-file-export.png",0).use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) } } finally { bitmap.recycle() }
        }
    }
    @Test fun pendingAndWithdrawnMediaRowsNeverOfferFileOpen() {
        var msg by mutableStateOf(message());var calls=0
        compose.setContent { MaterialTheme { MessageBubbleContent(msg,openFile={calls++}) } }
        compose.onNodeWithTag("message-file-open-${selection.media}").performClick();assertEquals(1,calls)
        compose.runOnIdle { msg=msg.copy(delivery=Delivery.Pending) };compose.onNodeWithTag("message-file-open-${selection.media}").assertDoesNotExist()
        compose.runOnIdle { msg=msg.copy(withdrawn=true) };compose.onNodeWithText("项目说明.txt").assertDoesNotExist()
    }
}
