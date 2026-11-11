package com.xmtx.im

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
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
import com.xmtx.im.platform.DocumentExport
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest

class DocumentExportActivityResultTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun externalCreateDocumentWritesVerifiedBytesThenExternalViewerReadsTheSavedFile()=external(false)
    @Test fun sourceFailureAfterCopyDeletesTheNewlyCreatedExternalDocument()=external(true)
    private fun external(failAfterCopy: Boolean) {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val source=File.createTempFile("export-source-",".txt",context.filesDir).apply { writeText("保存到用户选择的位置，并用系统应用打开。".repeat(300)) }
        val selection=fileTestSelection();val read=fileTestRead().let { it.copy(descriptor=it.descriptor.copy(byteCount=source.length(),checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }))) }
        var state by mutableStateOf<MessageFileState?>(null);var controller:MessageFileController?=null;var request:String?=null
        var result:Intent?=null;var opened:Intent?=null;var destination:Uri?=null
        val parent=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        try {
            compose.activityRule.scenario.onActivity { activity ->
                val owner=MessageFileController(selection,parent,MutableStateFlow(0L),{read},{expected,uri->
                    DocumentExport.copy(context.contentResolver,uri,source,expected.read.descriptor,System.nanoTime()+60_000_000_000) { assertEquals(read,expected.read) }
                    if(failAfterCopy) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
                },{DocumentExport.discard(context,it)},{state=it});controller=owner
                activity.setContent {
                    val lifecycle=LocalLifecycleOwner.current.lifecycle
                    val picker=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { response ->
                        result=response.data;destination=ActivityResultContracts.CreateDocument("text/plain").parseResult(response.resultCode,response.data)
                        request?.let { owner.result(it,destination) };request=null
                    }
                    val viewer=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { opened=it.data }
                    DisposableEffect(lifecycle) {
                        val observer=LifecycleEventObserver { _,event->if(event==Lifecycle.Event.ON_START) owner.foreground(true) else if(event==Lifecycle.Event.ON_STOP) owner.foreground(false) }
                        lifecycle.addObserver(observer);owner.foreground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
                        onDispose { lifecycle.removeObserver(observer);owner.foreground(false) }
                    }
                    MaterialTheme { Box(Modifier.fillMaxSize().safeDrawingPadding()) { MessageFileContent(read.descriptor,state,state?.available==true,save={
                        request=owner.begin()
                        if(request!=null) picker.launch(ActivityResultContracts.CreateDocument(read.descriptor.contentType).createIntent(context,read.descriptor.displayName).setComponent(ComponentName(instrumentation.context.packageName,DocumentSaveTestActivity::class.java.name)).putExtra("targetUid",android.os.Process.myUid()))
                    },retry={owner.retry()},open={
                        viewer.launch(savedDocumentIntent(Uri.parse(state!!.savedUri),read.descriptor.contentType).setComponent(ComponentName(instrumentation.context.packageName,DocumentOpenTestActivity::class.java.name)).putExtra("targetUid",android.os.Process.myUid()))
                    }) } }
                }
            }
            compose.waitUntil(5000) { state?.available==true };compose.onNodeWithText("保存到文件").performClick()
            compose.waitUntil(15000) { (if(failAfterCopy) state?.feedback?.contains("无法保存")==true else state?.phase==FileSavePhase.Saved) || result?.hasExtra("failure")==true }
            assertNull(result?.getStringExtra("failure"));assertTrue(result?.getBooleanExtra("isolated",false)==true)
            if(failAfterCopy) {
                assertNull(state?.savedUri);assertTrue(runCatching { context.contentResolver.openInputStream(destination!!)?.use { it.read() } }.isFailure)
                assertFalse(state!!.feedback!!.contains("手动删除"))
            } else {
                assertEquals(source.readText(),context.contentResolver.openInputStream(destination!!)?.bufferedReader()?.use { it.readText() })
                compose.onNodeWithText("打开已保存文件").performClick();compose.waitUntil(10000) { opened!=null }
                assertNull(opened?.getStringExtra("failure"));assertTrue(opened?.getBooleanExtra("isolated",false)==true);assertEquals(source.readText(),opened?.getStringExtra("contents"))
            }
        } finally {
            compose.runOnUiThread { controller?.close() };runBlocking { controller?.awaitClosed();destination?.let { DocumentExport.discard(context,it) } };parent.cancel();source.delete()
        }
    }
}
