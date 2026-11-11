package com.xmtx.im

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.Lifecycle
import org.junit.*
import org.junit.Assert.*

class CameraPermissionLauncherTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun permissionDenialBackgroundAndDisposalFenceLateGrants() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        Assume.assumeTrue(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)
        var permissionRequest:Int?=null;var launches=0;var failures=0;var visible by mutableStateOf(true)
        val registry=object:ActivityResultRegistry() {
            override fun <I,O> onLaunch(requestCode:Int,contract:ActivityResultContract<I,O>,input:I,options:ActivityOptionsCompat?) {
                if(contract is ActivityResultContracts.RequestPermission) permissionRequest=requestCode else launches++
            }
        }
        val owner=object:ActivityResultRegistryOwner {override val activityResultRegistry=registry}
        compose.setContent {CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
            if(visible) {val camera=rememberCameraCaptureLauncher {assertFalse(it);failures++}
                Button(onClick={camera(Uri.parse("content://test-only/output"))}) {Text("拍照")}}
        }}
        compose.onNodeWithText("拍照").performClick()
        compose.runOnIdle {registry.dispatchResult(requireNotNull(permissionRequest),false)}
        compose.runOnIdle {assertEquals(1,failures);assertEquals(0,launches)}
        compose.onNodeWithText("拍照").performClick()
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.runOnIdle {assertEquals(2,failures);registry.dispatchResult(requireNotNull(permissionRequest),true);assertEquals(0,launches)}
        compose.onNodeWithText("拍照").performClick()
        compose.runOnIdle {visible=false}
        compose.waitForIdle()
        compose.runOnIdle {assertEquals(3,failures);registry.dispatchResult(requireNotNull(permissionRequest),true)}
        compose.runOnIdle {assertEquals(0,launches)}
    }
}

class CameraCaptureGrantedTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun alreadyGrantedPermissionUsesTheExistingCaptureContractAndResult() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        Assume.assumeTrue(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)
        var request:Int?=null;var output:Uri?=null;var result:Boolean?=null
        val registry=object:ActivityResultRegistry() {
            override fun <I,O> onLaunch(requestCode:Int,contract:ActivityResultContract<I,O>,input:I,options:ActivityOptionsCompat?) {
                assertTrue(contract is AvatarCameraContract);request=requestCode;output=input as Uri
            }
        }
        val owner=object:ActivityResultRegistryOwner {override val activityResultRegistry=registry}
        val uri=Uri.parse("content://test-only/output")
        compose.setContent {CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
            val camera=rememberCameraCaptureLauncher {result=it}
            Button(onClick={camera(uri)}) {Text("拍照")}
        }}
        compose.onNodeWithText("拍照").performClick()
        compose.runOnIdle {assertEquals(uri,output);assertNull(result);registry.dispatchResult(requireNotNull(request),true)}
        compose.runOnIdle {assertEquals(true,result)}
    }
}
