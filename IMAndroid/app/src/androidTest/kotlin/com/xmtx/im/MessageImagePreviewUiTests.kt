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
import java.security.MessageDigest

class MessageImagePreviewUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),1,"海边.png","image/png",10000,ResourceChecksum("a".repeat(64)),ResourceState.Ready,800,600)
    private fun image(width: Int=320): MessagePreviewBytes {
        val bitmap=Bitmap.createBitmap(width,200,Bitmap.Config.ARGB_8888);val out=ByteString.newOutput()
        try {
            val canvas=android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(120,190,220));val paint=android.graphics.Paint().apply { color=android.graphics.Color.rgb(25,120,160) }
            canvas.drawRect(0f,110f,width.toFloat(),200f,paint);paint.color=android.graphics.Color.rgb(255,220,100);canvas.drawCircle(250f,45f,25f,paint)
            bitmap.compress(Bitmap.CompressFormat.PNG,100,out)
        } finally { bitmap.recycle() }
        val data=out.toByteString();val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(data.toByteArray()).joinToString("") { "%02x".format(it) })
        val read=MessageResourceRead(descriptor,MessageResourceSource(room,MessageId(actor.value),0,1),"A".repeat(32))
        return MessagePreviewBytes(read,ResourceVariantDescriptor(ResourceVariantKey(descriptor.key,ResourceRendition.Derived(actor.value,1)),checksum,data.size().toLong()),data,System.nanoTime()+60000000000)
    }
    private fun awaitImage() { compose.waitUntil(5000) { compose.onAllNodesWithTag("message-preview-image",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() } }
    private class Owner: LifecycleOwner { val registry=LifecycleRegistry(this);override val lifecycle: Lifecycle get()=registry }
    @Test fun foregroundAndSourceRemovalHideDecodedPixelsImmediately() {
        lateinit var owner:Owner;compose.runOnUiThread { owner=Owner();owner.registry.currentState=Lifecycle.State.RESUMED }
        var value by mutableStateOf<MessagePreviewBytes?>(image())
        compose.setContent { CompositionLocalProvider(LocalLifecycleOwner provides owner) { MaterialTheme { MessageImagePreview(value) } } };awaitImage()
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.STARTED };compose.onNodeWithTag("message-preview-image").assertDoesNotExist()
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.RESUMED };awaitImage()
        compose.runOnIdle { value=null };compose.onNodeWithTag("message-preview-image").assertDoesNotExist();compose.onNodeWithTag("message-preview-placeholder").assertExists()
    }
    @Test fun expiryAndOversizedDecodedDimensionsCannotKeepPreviousBitmap() {
        var value by mutableStateOf(image())
        compose.setContent { MaterialTheme { MessageImagePreview(value) } };awaitImage()
        compose.runOnIdle { value=value.copy(deadlineNanos=System.nanoTime()+2000000000) };awaitImage()
        compose.waitUntil(5000) { compose.onAllNodesWithTag("message-preview-image").fetchSemanticsNodes().isEmpty() }
        compose.runOnIdle { value=image(2000) };compose.onNodeWithTag("message-preview-image").assertDoesNotExist();compose.onNodeWithTag("message-preview-placeholder").assertExists()
    }
    @Test fun pickerDisplaysAuthorizedDerivedPixelsAndReportsVisibleInterestWithoutSelecting() {
        val preview=image();var selected=0;var interests=persistentListOf<ResourceKey>()
        val profile=ProfileView(actor,PublicIdentity(actor,PublicHandle("preview_owner"),"本人",AccountKind.Regular),null,ProfileState.Active,1,1)
        var state by mutableStateOf(AvatarResourcePickerState("picker",available=true,baseline=profile,entries=persistentListOf(ResourceCatalogEntry(descriptor,1000,1)),previews=persistentMapOf(descriptor.key to preview)))
        val app=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(ownProfile=profile))
        compose.setContent { MaterialTheme { AvatarResourcePickerScreen(app,state,true,{},{},{},{},{ selected++ },{},{},{},visible={ interests=it }) } };awaitImage()
        compose.runOnIdle { assertEquals(persistentListOf(descriptor.key),interests);assertEquals(0,selected) }
        if(InstrumentationRegistry.getArguments().getString("captureMediaPreview")=="true") {
            val instrumentation=InstrumentationRegistry.getInstrumentation();compose.waitForIdle();val bitmap=instrumentation.uiAutomation.takeScreenshot()
            try { instrumentation.targetContext.openFileOutput("message-image-preview.png",0).use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) } } finally { bitmap.recycle() }
        }
        compose.onNodeWithTag("avatar-resource-${descriptor.key.media}").performClick();compose.runOnIdle { assertEquals(1,selected);state=state.copy(previews=persistentMapOf()) }
        compose.onNodeWithTag("message-preview-image",useUnmergedTree=true).assertDoesNotExist();compose.onNodeWithText("海边.png").assertExists()
    }
}
