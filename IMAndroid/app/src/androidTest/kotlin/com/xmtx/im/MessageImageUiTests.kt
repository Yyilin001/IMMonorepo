package com.xmtx.im

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.*
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MessageImageUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val msg=MessageId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");private val media="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private val selection=MessageImageSelection(MediaMessageLocation(room,msg),media)
    private val descriptor=ResourceDescriptor(selection.key,1,"海边.png","image/png",1000,ResourceChecksum("a".repeat(64)),ResourceState.Ready,320,200)
    private fun message()=Message(msg,room,actor,"聊天图片",1000,media=MessageMedia(persistentListOf(media),persistentListOf(MessageMediaPresentation(media,MessageMediaKind.Image,"image/png",1000,descriptor))))
    private fun app(message: Message=message())=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(conversations=persistentListOf(Conversation(room,"图片测试群",kind=RoomKind.Group)),messages=persistentListOf(message)))
    private fun frame(width: Int=320): MessageImageFrame {
        val bitmap=Bitmap.createBitmap(width,200,Bitmap.Config.ARGB_8888);val out=ByteString.newOutput()
        try {
            val canvas=android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(120,190,220));val paint=android.graphics.Paint().apply { color=android.graphics.Color.rgb(25,120,160) }
            canvas.drawRect(0f,110f,width.toFloat(),200f,paint);paint.color=android.graphics.Color.rgb(255,220,100);canvas.drawCircle(width*0.78f,45f,25f,paint)
            bitmap.compress(Bitmap.CompressFormat.PNG,100,out)
        } finally { bitmap.recycle() }
        return MessageImageFrame(MessageResourceRead(descriptor,MessageResourceSource(room,msg,0,1),"A".repeat(32)),out.toByteString(),System.nanoTime()+60000000000,false)
    }
    private fun shown()=compose.onAllNodesWithTag("message-image-pixels").fetchSemanticsNodes().isNotEmpty()
    private fun awaitImage()=compose.waitUntil(5000) { shown() }
    private class Owner: LifecycleOwner { val registry=LifecycleRegistry(this);override val lifecycle: Lifecycle get()=registry }
    @Test fun previewDisplaysZoomControlsAndOriginalActionWithoutChangingMessage() {
        val app=app();var originals=0;var retries=0
        compose.setContent { MaterialTheme { MessageImageScreen(app,MessageImageState(selection,available=true,frame=remember { frame() }),selection,true,{ retries++ },{ originals++ },openSources=rememberMessageSourceFixture(actor,message())) } }
        awaitImage();compose.onNodeWithText("放大").performClick();compose.onNodeWithText("缩小").assertIsEnabled();compose.onNodeWithText("重置").performClick();compose.onNodeWithText("缩小").assertIsNotEnabled()
        compose.onNodeWithText("查看原图").performClick();compose.onNodeWithText("重新加载").performClick()
        compose.runOnIdle { assertEquals(1,originals);assertEquals(1,retries);assertEquals(message(),app.snapshot.messages.single()) }
        if(InstrumentationRegistry.getArguments().getString("captureMessageImage")=="true") {
            val instrumentation=InstrumentationRegistry.getInstrumentation();compose.waitForIdle();val bitmap=instrumentation.uiAutomation.takeScreenshot()
            try { instrumentation.targetContext.openFileOutput("message-image-viewer.png",0).use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) } } finally { bitmap.recycle() }
        }
    }
    @Test fun backgroundWithdrawalAndRevisionChangeHidePixelsBeforeControllerResponds() {
        lateinit var owner:Owner;compose.runOnUiThread { owner=Owner();owner.registry.currentState=Lifecycle.State.RESUMED }
        var app by mutableStateOf(app());val state=MessageImageState(selection,available=true,frame=frame())
        compose.setContent { CompositionLocalProvider(LocalLifecycleOwner provides owner) { MaterialTheme { MessageImageScreen(app,state,selection,true,{},{},openSources=rememberMessageSourceFixture(actor,app.snapshot.messages.single())) } } }
        awaitImage();compose.runOnIdle { owner.registry.currentState=Lifecycle.State.STARTED };compose.onNodeWithTag("message-image-pixels").assertDoesNotExist()
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.RESUMED };awaitImage()
        compose.runOnIdle { app=app.copy(snapshot=app.snapshot.copy(messages=persistentListOf(message().copy(revision=2)))) };compose.onNodeWithTag("message-image-pixels").assertDoesNotExist()
        compose.runOnIdle { app=app(message().copy(withdrawn=true)) };compose.onNodeWithText("查看原图").assertIsNotEnabled();compose.onNodeWithTag("message-image-pixels").assertDoesNotExist()
    }
    @Test fun expiryOversizedBitmapAndWrongRouteCannotDisplayPreviousPixels() {
        var state by mutableStateOf(MessageImageState(selection,available=true,frame=frame()));var active by mutableStateOf(true)
        compose.setContent { MaterialTheme { MessageImageScreen(app(),state,selection,active,{},{},openSources=rememberMessageSourceFixture(actor,message())) } };awaitImage()
        compose.runOnIdle { state=state.copy(frame=state.frame!!.copy(deadlineNanos=System.nanoTime()+1500000000)) }
        compose.waitUntil(5000) { !shown() }
        compose.runOnIdle { state=state.copy(frame=frame(2000)) };compose.onNodeWithTag("message-image-pixels").assertDoesNotExist()
        compose.runOnIdle { state=state.copy(frame=frame(2000).copy(original=true)) };awaitImage();compose.onNodeWithText("查看原图").assertIsNotEnabled()
        compose.runOnIdle { state=state.copy(frame=frame());active=false };compose.onNodeWithTag("message-image-pixels").assertDoesNotExist();compose.onNodeWithText("查看原图").assertIsNotEnabled()
    }
    @Test fun sharedNavigationRestoresOnlyIdsAndReturnsToChatDraft() {
        val model=AppViewModel(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application)
        val models=ViewModelStore().apply { put("image-test",model) };val restore=StateRestorationTester(compose);val app=installMediaNavigationSource(model,app())
        try {
            restore.setContent { MaterialTheme { SignedIn(app,SessionUi.SignedIn(actor),model) } }
            compose.onNodeWithText("图片测试群").performClick();compose.waitUntil(5000) {compose.onAllNodesWithTag("message-image-open-$media").fetchSemanticsNodes().isNotEmpty()};compose.onNodeWithText("发送消息…").performTextInput("图片返回后的草稿")
            compose.onNodeWithTag("message-image-open-$media").performClick();compose.onNodeWithText("查看图片").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("查看图片").assertIsDisplayed();compose.waitUntil(5000) {compose.onAllNodesWithText("海边.png").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("图片返回后的草稿").assertIsDisplayed()
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("我的").assertExists()
            val route:Route=Route.MessageImage(room.value,msg.value,media);val encoded=Json.encodeToString(route)
            assertEquals(route,Json.decodeFromString<Route>(encoded));assertFalse(encoded.contains("encoded"));assertFalse(encoded.contains("deadline"));assertFalse(encoded.contains("fileURL"))
        } finally { compose.runOnUiThread { models.clear() };awaitMediaNavigationClosed(model) }
    }
    @Test fun mediaRowOnlyOffersImagesAndWithdrawalRemovesTheAction() {
        var message by mutableStateOf(message());var opened:String?=null
        compose.setContent { MaterialTheme { MessageBubbleContent(message) { opened=it } } }
        compose.onNodeWithTag("message-image-open-$media").performClick();compose.runOnIdle { assertEquals(media,opened);message=message.copy(withdrawn=true) }
        compose.onNodeWithTag("message-image-open-$media").assertDoesNotExist()
    }
}
