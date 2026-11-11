package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.*
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ChatImagesUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val media="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),1,"海边.png","image/png",1000,ResourceChecksum("a".repeat(64)),ResourceState.Ready,320,200)
    private fun message(index: Int=1)=Message(MessageId("CCCCCCCC-CCCC-CCCC-CCCC-%012d".format(index)),room,actor,"今天的海边",1000+index.toLong(),media=MessageMedia(persistentListOf(media),persistentListOf(MessageMediaPresentation(media,MessageMediaKind.Image,"image/png",1000,descriptor))))
    private fun app(messages: PersistentList<Message> = persistentListOf(message()))=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(conversations=persistentListOf(Conversation(room,"图片测试群",kind=RoomKind.Group)),messages=messages))
    private fun bytes(message: Message): MessagePreviewBytes {
        val bitmap=Bitmap.createBitmap(320,200,Bitmap.Config.ARGB_8888);val output=ByteString.newOutput()
        try {
            val canvas=android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(120,190,220));val paint=android.graphics.Paint().apply { color=android.graphics.Color.rgb(25,120,160) }
            canvas.drawRect(0f,110f,320f,200f,paint);paint.color=android.graphics.Color.rgb(255,220,100);canvas.drawCircle(250f,45f,25f,paint)
            bitmap.compress(Bitmap.CompressFormat.PNG,100,output)
        } finally { bitmap.recycle() }
        val data=output.toByteString()
        return MessagePreviewBytes(MessageResourceRead(descriptor,MessageResourceSource(room,message.id,0,message.revision),"A".repeat(32)),
            ResourceVariantDescriptor(ResourceVariantKey(descriptor.key,ResourceRendition.Derived(media,1)),ResourceChecksum("b".repeat(64)),data.size().toLong()),data,System.nanoTime()+60000000000)
    }
    private fun shown()=compose.onAllNodesWithTag("message-preview-image",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    private fun awaitImage()=compose.waitUntil(5000) { shown() }
    private class Owner: LifecycleOwner { val registry=LifecycleRegistry(this);override val lifecycle: Lifecycle get()=registry }
    @Test fun chatShowsBoundPixelsAndHidesThemForRevisionRevocationBackgroundAndInactiveRoute() {
        val msg=message();val request=chatImageRequests(msg).single();val images=ChatImagesState(room,true,persistentMapOf(request to bytes(msg)))
        var state by mutableStateOf(app().copy(chatImages=images));var active by mutableStateOf(true);var opened:MessageId?=null
        lateinit var owner: Owner;compose.runOnUiThread { owner=Owner();owner.registry.currentState=Lifecycle.State.RESUMED }
        compose.setContent { CompositionLocalProvider(LocalLifecycleOwner provides owner) { MaterialTheme { Chat(state,SessionUi.SignedIn(actor),room,{ _,_->true },active=active,openImage={ message,_->opened=message }) } } }
        awaitImage();compose.onNodeWithTag("message-image-open-$media").performClick();compose.runOnIdle { assertEquals(msg.id,opened) }
        if(InstrumentationRegistry.getArguments().getString("captureChatImages")=="true") {
            val instrumentation=InstrumentationRegistry.getInstrumentation();compose.waitForIdle();val bitmap=instrumentation.uiAutomation.takeScreenshot()
            try { instrumentation.targetContext.openFileOutput("chat-images.png",0).use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) } } finally { bitmap.recycle() }
        }
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.STARTED };assertFalse(shown())
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.RESUMED };awaitImage()
        compose.runOnIdle { active=false };assertFalse(shown())
        compose.runOnIdle { active=true };awaitImage()
        compose.runOnIdle { state=state.copy(snapshot=state.snapshot.copy(messages=persistentListOf(msg.copy(revision=2)))) };assertFalse(shown())
        compose.runOnIdle { state=app().copy(chatImages=images,snapshot=app().snapshot.copy(revokedRooms=persistentSetOf(room))) };assertFalse(shown());compose.onNodeWithTag("message-image-open-$media").assertDoesNotExist()
    }
    @Test fun viewportInterestsChangeOnScrollAndClearOnLeaveOrWithdrawal() {
        val messages=(1..24).map(::message).toPersistentList();var state by mutableStateOf(app(messages));var active by mutableStateOf(true)
        var interests=persistentListOf<ChatImageRequest>()
        compose.setContent { MaterialTheme { Chat(state,SessionUi.SignedIn(actor),room,{ _,_->true },active=active,visibleImages={ selected,values -> assertEquals(room,selected);interests=values }) } }
        compose.waitUntil(5000) { interests.any { it.selection.location.message==messages.last().id } }
        compose.runOnIdle { assertTrue(interests.size in 1..12);assertFalse(interests.any { it.selection.location.message==messages.first().id }) }
        compose.onNodeWithTag("chat-timeline").performScrollToIndex(0)
        compose.waitUntil(5000) { interests.any { it.selection.location.message==messages.first().id } }
        compose.runOnIdle { assertFalse(interests.any { it.selection.location.message==messages.last().id });active=false }
        compose.waitUntil(5000) { interests.isEmpty() }
        compose.runOnIdle { active=true };compose.waitUntil(5000) { interests.isNotEmpty() }
        compose.runOnIdle { state=app(messages.map { it.copy(withdrawn=true) }.toPersistentList()) }
        compose.waitUntil(5000) { interests.isEmpty() }
    }
    @Test fun retryUsesExactMessageAndMismatchedSourceCannotBeRendered() {
        val msg=message();val request=chatImageRequests(msg).single();var retried:ChatImageRequest?=null
        var images by mutableStateOf(ChatImagesState(room,true,previews=persistentMapOf(request to bytes(message(2))),failed=persistentSetOf(request)))
        compose.setContent { MaterialTheme { MessageBubbleContent(msg,chatImages=images,showImagePreviews=true,retryImage={ retried=it }) } }
        assertFalse(shown());compose.onNodeWithText("重新加载缩略图").performClick();compose.runOnIdle { assertEquals(request,retried);images=images.copy(previews=persistentMapOf(request to bytes(msg)),failed=persistentSetOf()) }
        awaitImage();compose.onNodeWithText("重新加载缩略图").assertDoesNotExist()
    }
}
