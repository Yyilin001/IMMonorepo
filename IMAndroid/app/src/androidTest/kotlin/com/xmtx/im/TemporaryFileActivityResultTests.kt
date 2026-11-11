package com.xmtx.im

import android.content.ComponentName
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.core.app.ActivityOptionsCompat
import kotlinx.collections.immutable.persistentListOf
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class TemporaryFileActivityResultTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun directViewerReceivesReadOnlyContentAndReturnReleasesIt()=external(false)
    @Test fun sharingKeepsFileReadableAfterItsSourceRouteCloses()=external(true)
    private fun external(share: Boolean) {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val source=File.createTempFile("temporary-original-",".txt",context.filesDir).apply {writeText("跨进程临时原件".repeat(1000))}
        val read=fileTestRead().let {it.copy(descriptor=it.descriptor.copy(byteCount=source.length(),checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") {"%02x".format(it)})))}
        val parent=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate);val changes=MutableStateFlow(0L)
        val files=TemporaryResourceFiles(context,parent,changes) {true};var lease:TemporaryResourceLease?=null
        var state by mutableStateOf<MessageFileState?>(null);var controller:MessageFileController?=null;var result:Intent?=null;var forwardedCode:Int?=null;var bridge:ActivityResultRegistry?=null
        try {
            compose.activityRule.scenario.onActivity {activity->
                val owner=MessageFileController(fileTestSelection(),parent,changes,{read},{_,_->},{true},{state=it},prepare={files.prepare(AuthorizedOriginalRead(it.read,System.nanoTime()+60_000_000_000),source).also {lease=it}});controller=owner
                activity.setContent {
                    val lifecycle=LocalLifecycleOwner.current.lifecycle
                    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {response->
                        result=response.data;forwardedCode?.let {bridge!!.dispatchResult(it,response.resultCode,response.data)};forwardedCode=null
                    }
                    val registry=remember { object:ActivityResultRegistry() {
                        override fun <I,O> onLaunch(requestCode: Int,contract: ActivityResultContract<I,O>,input:I,options: ActivityOptionsCompat?) {
                            forwardedCode=requestCode;val intent=contract.createIntent(context,input)
                            @Suppress("DEPRECATION") val target=if(share) requireNotNull(intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)) else intent
                            assertEquals(if(share) Intent.ACTION_CHOOSER else Intent.ACTION_VIEW,intent.action)
                            target.component=ComponentName(instrumentation.context.packageName,TemporaryFileReceiverTestActivity::class.java.name)
                            launcher.launch(target.putExtra("targetUid",android.os.Process.myUid()))
                        }
                    } };bridge=registry
                    val registryOwner=remember { object:ActivityResultRegistryOwner {override val activityResultRegistry=registry} }
                    DisposableEffect(lifecycle) {
                        val observer=LifecycleEventObserver {_,event->if(event==Lifecycle.Event.ON_START) owner.foreground(true) else if(event==Lifecycle.Event.ON_STOP) owner.foreground(false)}
                        lifecycle.addObserver(observer);owner.foreground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
                        onDispose {lifecycle.removeObserver(observer);owner.foreground(false)}
                    }
                    val actor=UserId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD");val selection=fileTestSelection()
                    val message=Message(selection.location.message,selection.location.room,actor,"",1000,media=MessageMedia(persistentListOf(selection.media),persistentListOf(MessageMediaPresentation(selection.media,MessageMediaKind.File,"text/plain",read.descriptor.byteCount,read.descriptor))))
                    val app=AppState(SessionUi.SignedIn(actor),ClientSnapshot(messages=persistentListOf(message)))
                    CompositionLocalProvider(LocalActivityResultRegistryOwner provides registryOwner) {
                        MaterialTheme {Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                            MessageFileScreen(app,state,selection,true,owner::begin,owner::result,owner::pickerFailed,owner::retry,owner::openFailed,
                                present=owner::present,claim=owner::claimPresentation,launched={id->owner.presentationLaunched(id);if(share) owner.close()},returned=owner::presentationReturned,failed=owner::presentationFailed,openSources=rememberMessageSourceFixture(actor,message))
                        }}
                    }
                }
            }
            compose.waitUntil(5000) {state?.available==true};compose.onNodeWithText(if(share) "分享文件" else "用其他应用打开").performClick()
            compose.waitUntil(15000) {result!=null}
            assertNull(result?.getStringExtra("failure"));assertTrue(result?.getBooleanExtra("isolated",false)==true);assertEquals(source.readText(),result?.getStringExtra("contents"))
            if(share) {
                assertTrue(lease!!.active);runBlocking {files.close()};assertFalse(lease!!.active)
            } else compose.waitUntil(5000) {state?.opening==false && lease?.active==false}
            assertTrue(runCatching {context.contentResolver.openInputStream(lease!!.uri)?.close()}.isFailure)
        } finally {
            compose.runOnUiThread {controller?.close()};runBlocking {controller?.awaitClosed();files.close()};parent.cancel();source.delete()
        }
    }
}
