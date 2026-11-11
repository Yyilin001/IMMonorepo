package com.xmtx.im

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.CameraCaptureFiles
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class CameraActivityResultTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun externalCameraGetsOnlyOutputGrantAndReturnsIntoNormalizedCropState() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val external=ComponentName(InstrumentationRegistry.getInstrumentation().context.packageName,CameraOutputTestActivity::class.java.name)
        val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        val profile=ProfileView(actor,PublicIdentity(actor,PublicHandle("camera_owner"),"我的资料",AccountKind.Regular),null,ProfileState.Active,1,1)
        var state by mutableStateOf(AvatarEditorState("capture-test"));var externalResult:Intent?=null;var output:Uri?=null
        compose.activityRule.scenario.onActivity { activity -> activity.setContentForCameraTest {
            val scope=rememberCoroutineScope();val lifecycle=LocalLifecycleOwner.current.lifecycle
            val editor=remember { AvatarEditorController("capture-test",actor,scope,{profile},{ error("library must not read camera output") },{p,_->p},{_,_->error("capture must not submit")},{},{},{state=it},{CameraCaptureFiles.create(context)}) }
            val launcher=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result -> externalResult=result.data;editor.captured(result.resultCode==Activity.RESULT_OK) }
            DisposableEffect(editor,lifecycle) {
                val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_START) editor.foreground(true) else if(event==Lifecycle.Event.ON_STOP) editor.foreground(false) }
                lifecycle.addObserver(observer);editor.foreground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
                onDispose { lifecycle.removeObserver(observer);editor.close() }
            }
            MaterialTheme { Button(onClick={ editor.takePicture { uri -> output=uri;launcher.launch(AvatarCameraContract().createIntent(context,uri).setComponent(external).putExtra("targetUid",android.os.Process.myUid())) } }) { Text("测试拍照") } }
        } }
        compose.onNodeWithText("测试拍照").performClick()
        compose.waitUntil(15_000) { state.photo!=null || externalResult?.hasExtra("failure")==true }
        compose.runOnIdle {
            assertNull(externalResult?.getStringExtra("failure"));assertTrue(externalResult?.getBooleanExtra("isolated",false)==true)
            assertEquals(ResourceDimensions(80,60),state.photo?.dimensions);assertTrue(state.openCrop);assertNull(state.source)
            assertFalse(File(context.cacheDir,"camera-captures-v1/${output!!.lastPathSegment}").exists())
        }
    }
}

private fun MainActivity.setContentForCameraTest(content: @Composable ()->Unit)=setContent(content=content)
