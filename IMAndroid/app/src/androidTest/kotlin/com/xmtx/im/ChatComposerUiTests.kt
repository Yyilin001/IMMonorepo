package com.xmtx.im

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ChatComposerUiTests {
    @get:Rule val compose=createComposeRule()
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id())
    private fun attachment()=SendAttachment(id(),id(),"旅行照片.jpg","image/jpeg",1500)
    @Test fun systemKindShowsNotificationOnlyReasonEvenBeforeCapabilityAndNeverRestrictsSupportByKind() {
        val draft=ConversationDraft(room,text="保留的草稿")
        var state by mutableStateOf(ChatComposerState(id(),room,draft,draft.text,available=true,loading=false,directAccountKind=AccountKind.System,rich=MessageRichContent(replyTo=MessageId(id()))))
        compose.setContent {MaterialTheme {Column(Modifier.fillMaxSize().safeDrawingPadding(),verticalArrangement=Arrangement.Bottom) {ChatComposerBar(room,state,true,{_,_->},{false},{_,_->},{},{_,_->},{},{},cancelReply={})}}}
        compose.onNodeWithText("此系统账号仅用于发送通知").assertIsDisplayed();compose.onNodeWithText("保留的草稿").assertExists()
        compose.onNodeWithText("取消回复").assertIsNotEnabled();compose.onNodeWithTag("persistent-message-draft").assertIsNotEnabled();compose.onNodeWithContentDescription("发送").assertIsNotEnabled();compose.onNodeWithContentDescription("添加附件").assertIsNotEnabled()
        compose.runOnIdle {state=state.copy(canSend=true)};compose.onNodeWithContentDescription("发送").assertIsNotEnabled()
        compose.waitForIdle();val screenshot=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        try {context.openFileOutput("system-account-composer.png",0).use {assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG,100,it))}} finally {screenshot.recycle()}
        compose.runOnIdle {state=state.copy(directAccountKind=AccountKind.CustomerSupport)}
        compose.onNodeWithText("此系统账号仅用于发送通知").assertDoesNotExist();compose.onNodeWithContentDescription("发送").assertIsEnabled()
        compose.runOnIdle {state=state.copy(canSend=false)};compose.onNodeWithText("当前无法向此会话发送消息").assertIsDisplayed()
    }
    @Test fun directDenialDisablesNewContentButKeepsDraftAttachmentsAndConfirmationRetry() {
        val attachment=attachment();val draft=ConversationDraft(room,text="未发送草稿",attachments=persistentListOf(attachment),attachmentOrder=persistentListOf(attachment.id))
        var state by mutableStateOf(ChatComposerState(id(),room,draft,draft.text,available=true,loading=false,canSend=false,feedback="结果未知，请重试",contentLocked=true))
        var retries=0
        compose.setContent {MaterialTheme {Column(Modifier.fillMaxSize().safeDrawingPadding(),verticalArrangement=Arrangement.Bottom) {ChatComposerBar(room,state,true,{_,_->},{false},{_,_->},{},{_,_->},{},{retries++})}}}
        compose.onNodeWithText("当前无法向此会话发送消息").assertIsDisplayed()
        compose.onNodeWithTag("persistent-message-draft").assertIsNotEnabled();compose.onNodeWithText("未发送草稿").assertExists()
        compose.onNodeWithContentDescription("添加附件").assertIsNotEnabled();compose.onNodeWithContentDescription("发送").assertIsNotEnabled()
        compose.onNodeWithTag("remove-attachment-${attachment.asset}").assertIsNotEnabled()
        compose.onNodeWithText(attachment.displayName).assertExists();compose.waitForIdle()
        val screenshot=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        try {context.openFileOutput("direct-capability.png",0).use {assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG,100,it))}} finally {screenshot.recycle()}
        compose.onNodeWithText("重试").assertIsEnabled().performClick()
        compose.runOnIdle {assertEquals(1,retries);state=state.copy(canSend=true,contentLocked=false,feedback=null)}
        compose.onNodeWithText("当前无法向此会话发送消息").assertDoesNotExist();compose.onNodeWithTag("persistent-message-draft").assertIsEnabled()
        compose.onNodeWithContentDescription("发送").assertIsEnabled();compose.onNodeWithContentDescription("添加附件").assertIsEnabled()
        compose.runOnIdle {state=state.copy(canSend=false)}
        compose.onNodeWithTag("remove-attachment-${attachment.asset}").assertIsEnabled()
    }
    @Test fun importedTasksShowMixedOrderAndHideReplacementWhileOutcomeIsUnknown() {
        val local=attachment();val remote=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(room,MessageId(id()),id()),ResourceUsage.Attachment(room),id()))
        val now=System.currentTimeMillis();val intent=SendIntent(id(),actor,room,id(),"导入消息",persistentListOf(local),now,now+86400000,
            serverImports=persistentListOf(remote),attachmentOrder=persistentListOf(remote.id,local.id))
        var task by mutableStateOf(SendIntentStatus(intent,SendIntentPhase.Preparing))
        compose.setContent {MaterialTheme {SendTasksScreen(AppState(SessionUi.SignedIn(actor),ClientSnapshot(sendIntents=persistentListOf(task))),room,true,{},{})}}
        compose.onNodeWithText("导入的附件").assertIsDisplayed();compose.onNodeWithText(local.displayName).assertIsDisplayed()
        assertTrue(compose.onNodeWithText("导入的附件").fetchSemanticsNode().boundsInRoot.top<compose.onNodeWithText(local.displayName).fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithText("放弃发送").performClick();compose.onNodeWithText("放弃这条消息？").assertIsDisplayed()
        compose.runOnIdle {task=SendIntentStatus(intent.copy(preparation=SendPreparation.HandedOff),SendIntentPhase.Confirming)}
        compose.onNodeWithText("放弃这条消息？").assertDoesNotExist();compose.onNodeWithText("放弃发送").assertDoesNotExist();compose.onNodeWithText("重试").assertDoesNotExist()
    }
    @Test fun attachmentOnlySendRemovalAndUnavailableSourceHaveCorrectControls() {
        val attachment=attachment();var state by mutableStateOf(ChatComposerState("editor",room,ConversationDraft(room,1,attachments=persistentListOf(attachment)),available=true,loading=false))
        var sent=0;var removed:String?=null;var edit:String?=null
        compose.setContent { MaterialTheme { ChatComposerBar(room,state,true,{ _,text -> edit=text;state=state.copy(text=text) },{ false },{ _,_-> },{}, { _,asset->removed=asset },{ sent++ },{}) } }
        compose.onNodeWithContentDescription("发送").assertIsEnabled().performClick();compose.onNodeWithTag("persistent-message-draft").performTextInput("补充正文")
        compose.onNodeWithTag("remove-attachment-${attachment.asset}").performClick();compose.runOnIdle { assertEquals(1,sent);assertEquals(attachment.asset,removed);assertEquals("补充正文",edit);state=state.copy(unavailable=persistentSetOf(attachment.asset)) }
        compose.onNodeWithContentDescription("发送").assertIsNotEnabled();compose.onNodeWithText("原件不可用，请移除").assertExists()
        compose.runOnIdle { state=state.copy(preparing=true) };compose.onNodeWithContentDescription("添加附件").assertIsNotEnabled()
    }
    @Test fun attachmentMenuRoutesPhotoDocumentAndCameraActions() {
        val state=ChatComposerState("editor",room,ConversationDraft(room),available=true,loading=false)
        var photos=0;var documents=0;var camera=0
        compose.setContent { MaterialTheme { ChatComposerBar(room,state,true,{ _,_-> },{ photos++;false },{ _,_-> },{},{ _,_-> },{},{},
            beginDocument={ documents++;false },takePicture={ _,_->camera++ }) } }
        compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("选择图片").performClick()
        compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("选择文件（最多 50 MB）").performClick()
        compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("拍照").performClick()
        compose.runOnIdle { assertEquals(1,photos);assertEquals(1,documents);assertEquals(1,camera) }
    }
    @Test fun taskConfirmationCannotDiscardAnUnknownSendAndSharedNavigationRestoresDraft() {
        val now=System.currentTimeMillis();val intent=SendIntent(id(),actor,room,id(),"尚未发送的图片",persistentListOf(attachment()),now,now+86400000)
        var app by mutableStateOf(AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"发送测试群",kind=RoomKind.Group)),sendIntents=persistentListOf(SendIntentStatus(intent,SendIntentPhase.Preparing)))))
        val model=AppViewModel(context.applicationContext as Application);val models=ViewModelStore().apply { put("composer",model) };val restore=StateRestorationTester(compose)
        try {
            restore.setContent { MaterialTheme { SignedIn(app,SessionUi.SignedIn(actor),model) } }
            compose.onNodeWithText("发送测试群").performClick();compose.onNodeWithText("发送消息…").performTextInput("返回后继续编辑")
            compose.onNodeWithText("待发送消息（1）").performClick();compose.onNodeWithText("待发送消息").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("尚未发送的图片").assertExists()
            compose.onNodeWithText("放弃发送").performClick();compose.onNodeWithText("放弃这条消息？").assertExists()
            compose.runOnIdle { app=app.copy(snapshot=app.snapshot.copy(sendIntents=persistentListOf(SendIntentStatus(intent.copy(preparation=SendPreparation.HandedOff),SendIntentPhase.Confirming)))) }
            compose.onNodeWithText("放弃这条消息？").assertDoesNotExist();compose.onNodeWithText("放弃发送").assertDoesNotExist()
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("返回后继续编辑").assertIsDisplayed()
            compose.runOnIdle { app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room),sendIntents=persistentListOf(SendIntentStatus(intent,SendIntentPhase.NeedsAttention)))) }
            compose.onNodeWithText("待发送消息（1）").assertIsEnabled().performClick()
            compose.onNodeWithText("重试").assertIsNotEnabled();compose.onNodeWithText("放弃发送").assertIsEnabled()
        } finally { compose.runOnUiThread { models.clear() } }
    }
    @Test fun actualProviderPhotoAndTextRestoreAfterReopenThenSubmitAtomically() {
        val device=DeviceId(id());var store=openBoundFixtureStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var state by mutableStateOf<ChatComposerState?>(null);var imageState by mutableStateOf<DraftImageState?>(null);var repository:ChatComposerRepository?=null
        val capture=runBlocking { CameraCaptureFiles.create(context) }
        val bitmap=Bitmap.createBitmap(320,200,Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(android.graphics.Color.rgb(90,175,205))
            context.contentResolver.openOutputStream(capture.uri,"w")!!.use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG,90,it)) }
        } finally { bitmap.recycle() }
        try {
            compose.runOnIdle { repository=ChatComposerRepository(context,actor,store,files,publishImage={ imageState=it }) { state=it };repository!!.foreground(true);repository!!.activate(room) }
            compose.setContent { MaterialTheme { Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                Text("图片消息草稿");Spacer(Modifier.weight(1f))
                ChatComposerBar(room,state,true,{ id,text->repository?.edit(id,text) },{ repository?.beginPick(it)==true },{ id,uri->repository?.picked(id,uri) },{ repository?.pickerFailed(it) },{ id,asset->repository?.remove(id,asset) },{ repository?.send(it) },{ repository?.retry(it) },openImage={ repository?.activate(room,it) },move={id,asset,offset->repository?.move(id,asset,offset)})
            } } }
            compose.waitUntil(5000) { state?.draft!=null }
            compose.onNodeWithTag("persistent-message-draft").performTextInput("照片和正文一起保存")
            compose.runOnIdle { assertTrue(repository!!.beginPick(state!!.id));repository!!.pickedPhotos(state!!.id,listOf(capture.uri,capture.uri.buildUpon().appendQueryParameter("selection","2").build())) }
            compose.waitUntil(10000) { state?.attachments?.size==2 && state?.preparing==false }
            capture.close();var attachments=state!!.attachments
            runBlocking { repository!!.close();files.close();store.close() }
            store=openBoundFixtureStore(context,actor,device);files=ManagedResourceFiles(context,store)
            compose.runOnIdle { state=null;repository=ChatComposerRepository(context,actor,store,files,publishImage={ imageState=it }) { state=it };repository!!.foreground(true);repository!!.activate(room) }
            compose.waitUntil(5000) { state?.draft!=null && state?.attachments?.size==2 && state?.thumbnails?.size==2 }
            compose.onNodeWithText("照片和正文一起保存").assertExists();assertEquals(attachments,state!!.attachments)
            compose.waitUntil(5000) { compose.onAllNodesWithTag("draft-thumbnail-${attachments.first().asset}",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() }
            compose.runOnIdle { repository!!.foreground(false) }
            compose.onNodeWithTag("draft-thumbnail-${attachments.first().asset}",useUnmergedTree=true).assertDoesNotExist();assertTrue(state!!.thumbnails.isEmpty())
            compose.runOnIdle { repository!!.foreground(true) }
            compose.waitUntil(5000) { state?.thumbnails?.size==2 && compose.onAllNodesWithTag("draft-thumbnail-${attachments.first().asset}",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() }
            val first=attachments.first();compose.onNodeWithTag("draft-move-forward-${first.asset}").performClick()
            compose.waitUntil(5000) { state?.attachments?.first()?.asset==attachments.last().asset };attachments=state!!.attachments
            val editorId=state!!.id
            compose.onNodeWithTag("composer-attachments").performScrollToNode(hasTestTag("open-draft-image-${attachments.first().asset}"))
            compose.onNodeWithTag("open-draft-image-${attachments.first().asset}").performClick()
            compose.waitUntil(5000) { imageState?.photo!=null && imageState?.loading==false };assertNull(state)
            compose.runOnIdle { repository!!.edit(editorId,"迟到旧编辑器");repository!!.foreground(false) };assertNull(imageState!!.photo)
            compose.runOnIdle { repository!!.foreground(true) };compose.waitUntil(5000) { imageState?.photo!=null }
            val wrongRoom=RoomId(id());compose.runOnIdle { repository!!.activate(wrongRoom,attachments.first().asset) }
            compose.waitUntil(5000) { imageState?.selection?.room==wrongRoom && imageState?.feedback!=null };assertNull(imageState!!.photo)
            compose.runOnIdle { repository!!.activate(room) };compose.waitUntil(5000) { state?.thumbnails?.size==2 }
            assertEquals(attachments,state!!.attachments);assertEquals("照片和正文一起保存",state!!.text);assertNull(imageState)
            val previousEditor=state!!.id
            compose.runOnIdle { repository!!.activate(null);repository!!.activate(room) }
            compose.waitUntil(5000) { state?.id!=null && state?.id!=previousEditor && state?.thumbnails?.size==2 }
            assertEquals(attachments,state!!.attachments);assertEquals("照片和正文一起保存",state!!.text)
            if(InstrumentationRegistry.getArguments().getString("captureComposer")=="true") {
                compose.waitForIdle();val image=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                try { context.openFileOutput("chat-composer.png",0).use { image.compress(Bitmap.CompressFormat.PNG,100,it) } } finally { image.recycle() }
            }
            if(InstrumentationRegistry.getArguments().getString("captureAttachmentMenu")=="true") {
                compose.onNodeWithContentDescription("添加附件").performClick();compose.waitForIdle()
                val image=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                try { context.openFileOutput("chat-attachment-menu.png",0).use { image.compress(Bitmap.CompressFormat.PNG,100,it) } } finally { image.recycle() }
                compose.onNodeWithText("拍照").performClick()
            }
            compose.onNodeWithContentDescription("发送").performClick();compose.waitUntil(5000) { state?.text=="" && state?.attachments?.isEmpty()==true && state?.sending==false }
            runBlocking {
                val sent=store.sendIntents().single().intent;assertEquals("照片和正文一起保存",sent.text);assertEquals(attachments,sent.attachments)
                assertTrue(store.conversationDraft(room).empty);assertEquals(2,store.resourceUploads().size);assertTrue(state!!.thumbnails.isEmpty())
            }
        } finally { capture.close();runBlocking { repository?.close();files.close() };store.close() }
    }
}
