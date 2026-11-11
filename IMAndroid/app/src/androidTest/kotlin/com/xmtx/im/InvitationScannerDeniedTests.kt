package com.xmtx.im

import android.Manifest
import android.content.pm.PackageManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.*
import org.junit.Assert.*

class InvitationScannerDeniedTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun deniedPermissionKeepsPasteAvailableAndDoesNotOpenCamera() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        Assume.assumeTrue(ContextCompat.checkSelfPermission(instrumentation.targetContext,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)
        var visible by mutableStateOf(true)
        compose.setContent {MaterialTheme {if(visible) InvitationScanner({visible=false}) {fail("No camera permission")}}}
        compose.onNodeWithText("允许使用相机").performClick()
        var deny:AccessibilityNodeInfo?=null
        compose.waitUntil(5000) {
            val root=instrumentation.uiAutomation.rootInActiveWindow
            deny=listOf("com.android.permissioncontroller","com.google.android.permissioncontroller").asSequence()
                .flatMap { root?.findAccessibilityNodeInfosByViewId("$it:id/permission_deny_button").orEmpty().asSequence() }.firstOrNull()
            deny!=null
        }
        assertTrue(requireNotNull(deny).performAction(AccessibilityNodeInfo.ACTION_CLICK))
        compose.waitUntil(5000) {compose.onAllNodesWithText("未获得相机权限",substring=true).fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("invitation-camera-preview").assertDoesNotExist()
        compose.onNodeWithText("返回粘贴链接").performClick()
        compose.onNodeWithTag("invitation-scanner").assertDoesNotExist()
    }
}
