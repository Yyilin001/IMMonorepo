package com.xmtx.im

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.camera.view.PreviewView
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import org.junit.*
import org.junit.Assert.*
import java.util.concurrent.atomic.AtomicInteger

class InvitationQrUiTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun renderedQrDecodesInDarkThemeAndLeavesNoImageAfterDismissal() {
        val secret=InvitationSecret("A".repeat(43));var visible by mutableStateOf(true)
        compose.setContent { MaterialTheme(colorScheme=darkColorScheme()) { if(visible) InvitationQrImage(secret,"test") } }
        compose.waitUntil(5000) {compose.onAllNodesWithTag("invite-qr/test").fetchSemanticsNodes().isNotEmpty()}
        val bitmap=compose.onNodeWithTag("invite-qr/test").captureToImage().asAndroidBitmap()
        val pixels=ByteArray(bitmap.width*bitmap.height) { i ->
            val c=bitmap.getPixel(i%bitmap.width,i/bitmap.width)
            ((android.graphics.Color.red(c)*299+android.graphics.Color.green(c)*587+android.graphics.Color.blue(c)*114)/1000).toByte()
        }
        assertEquals(secret,decodeInvitationQr(bitmap.width,bitmap.height,pixels))
        compose.runOnIdle {visible=false};compose.onNodeWithContentDescription("群邀请二维码").assertDoesNotExist()
    }
    @Test fun realCameraStreamsAndReleasesWhenScannerLeavesForeground() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        Assume.assumeTrue(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)
        val manager=context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val releases=AtomicInteger();var occupied:String?=null
        val callback=object:CameraManager.AvailabilityCallback() {
            override fun onCameraUnavailable(cameraId:String) {occupied=cameraId}
            override fun onCameraAvailable(cameraId:String) {if(occupied==cameraId) releases.incrementAndGet()}
        }
        manager.registerAvailabilityCallback(callback,Handler(Looper.getMainLooper()))
        var show by mutableStateOf(true)
        try {
            compose.setContent {MaterialTheme {if(show) InvitationScanner({show=false}) {fail("Emulated scene unexpectedly contained an invitation")}}}
            fun streaming():Boolean {
                var found=false
                fun visit(view:View) {if(view is PreviewView && view.previewStreamState.value==PreviewView.StreamState.STREAMING) found=true
                    if(view is ViewGroup) for(i in 0 until view.childCount) visit(view.getChildAt(i))}
                // Dialog has its own window; inspect the view roots exposed by instrumentation.
                compose.runOnUiThread {
                    android.view.inspector.WindowInspector.getGlobalWindowViews().forEach(::visit)
                }
                return found
            }
            compose.waitUntil(20000) {streaming()}
            val before=releases.get()
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            compose.waitUntil(10000) {releases.get()>before}
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.onNodeWithTag("invitation-scanner").assertDoesNotExist()
        } finally {compose.runOnUiThread {show=false;manager.unregisterAvailabilityCallback(callback)}}
    }
}
