package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.*
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import org.junit.Rule
import org.junit.Test
import java.security.MessageDigest

class AuthorizedAvatarUiTests {
    @get:Rule val compose=createComposeRule()
    private class Owner: LifecycleOwner {
        val registry=LifecycleRegistry(this)
        override val lifecycle: Lifecycle get()=registry
    }
    private fun image(color: Int,expires: Long=System.nanoTime()+60_000_000_000): AvatarPresentationBytes {
        val bitmap=Bitmap.createBitmap(120,80,Bitmap.Config.ARGB_8888);val output=ByteString.newOutput()
        try { bitmap.eraseColor(color);bitmap.compress(Bitmap.CompressFormat.PNG,100,output) } finally { bitmap.recycle() }
        val data=output.toByteString();return AvatarPresentationBytes(AvatarContent("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",1,
            ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(data.toByteArray()).joinToString("") { "%02x".format(it) }),data.size().toLong()),data,expires)
    }
    private fun awaitImage() {
        try { compose.waitUntil(5000) { compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() } }
        catch(error: Exception) { throw AssertionError(compose.onRoot(useUnmergedTree=true).printToString(),error) }
    }
    @Test fun leavingForegroundImmediatelyHidesProtectedPixelsAndReturnCanDecodeAgain() {
        lateinit var owner:Owner;compose.runOnUiThread { owner=Owner();owner.registry.currentState=Lifecycle.State.RESUMED }
        var picture by mutableStateOf<AvatarPresentationBytes?>(image(android.graphics.Color.rgb(23,107,82)))
        compose.setContent { CompositionLocalProvider(LocalLifecycleOwner provides owner) { MaterialTheme { Avatar("我",144,picture) } } }
        awaitImage()
        if(InstrumentationRegistry.getArguments().getString("captureAvatar")=="true") {
            val context=InstrumentationRegistry.getInstrumentation().targetContext
            context.openFileOutput("authorized-avatar.png",0).use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it) }
        }
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.STARTED };compose.onNodeWithTag("avatar-image",useUnmergedTree=true).assertDoesNotExist()
        compose.onNodeWithTag("avatar-placeholder",useUnmergedTree=true).assertExists()
        compose.runOnIdle { owner.registry.currentState=Lifecycle.State.RESUMED };awaitImage()
        compose.runOnIdle { picture=null };compose.onNodeWithTag("avatar-image",useUnmergedTree=true).assertDoesNotExist()
    }
    @Test fun expiryRemovesDecodedBitmapWithoutAnotherParentUpdate() {
        var photo by mutableStateOf(image(android.graphics.Color.BLUE))
        compose.setContent { MaterialTheme { Avatar("我",96,photo) } };awaitImage()
        compose.runOnIdle { photo=photo.copy(deadlineNanos=System.nanoTime()+2_000_000_000) };awaitImage()
        compose.waitUntil(5000) { compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("avatar-placeholder",useUnmergedTree=true).assertExists()
    }
    @Test fun malformedEncodedContentRemainsPlaceholderAndCannotKeepPreviousBitmap() {
        var picture by mutableStateOf(image(android.graphics.Color.RED))
        compose.setContent { MaterialTheme { Avatar("我",96,picture) } };awaitImage()
        compose.runOnIdle { val bytes=ByteString.copyFromUtf8("not an image");picture=picture.copy(encoded=bytes,content=picture.content.copy(byteCount=bytes.size().toLong())) }
        compose.onNodeWithTag("avatar-image",useUnmergedTree=true).assertDoesNotExist();compose.onNodeWithTag("avatar-placeholder",useUnmergedTree=true).assertExists()
    }
}
