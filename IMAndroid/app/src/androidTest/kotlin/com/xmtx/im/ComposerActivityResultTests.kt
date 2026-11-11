package com.xmtx.im

import android.app.Activity
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
import com.xmtx.im.platform.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

class ComposerActivityResultTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun externalCameraReturnsIntoPersistentDraftThenSendIntent()=external(true)
    @Test fun externalDocumentReadGrantIsCopiedBeforeSubmittingTheDraft()=external(false)
    @Test fun externalMultiPhotoSelectionPreservesClipDataOrderAndThumbnails()=external(false,true)
    private fun external(camera: Boolean,photos: Boolean=false) {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        fun id()=UUID.randomUUID().toString().uppercase()
        val actor=UserId(id());val room=RoomId(id());val store=openBoundFixtureStore(context,actor,DeviceId(id()));val files=ManagedResourceFiles(context,store)
        var state by mutableStateOf<ChatComposerState?>(null);lateinit var repository: ChatComposerRepository;var owner:ChatComposerRepository?=null
        var result:Intent?=null;var output:Uri?=null
        val external=ComponentName(instrumentation.context.packageName,if(photos) PhotoSelectionTestActivity::class.java.name else if(camera) CameraOutputTestActivity::class.java.name else DocumentOutputTestActivity::class.java.name)
        try {
            compose.activityRule.scenario.onActivity { activity ->
                repository=ChatComposerRepository(context,actor,store,files) { state=it };owner=repository;repository.activate(room)
                activity.setContent {
                    val lifecycle=LocalLifecycleOwner.current.lifecycle
                    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { response ->
                        result=response.data
                        state?.let { if(photos) repository.pickedPhotos(it.id,ActivityResultContracts.PickMultipleVisualMedia(2).parseResult(response.resultCode,response.data)) else if(camera) repository.captured(it.id,response.resultCode==Activity.RESULT_OK) else repository.documentPicked(it.id,if(response.resultCode==Activity.RESULT_OK) response.data?.data else null) }
                    }
                    DisposableEffect(lifecycle) {
                        val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_START) repository.foreground(true) else if(event==Lifecycle.Event.ON_STOP) repository.foreground(false) }
                        lifecycle.addObserver(observer);repository.foreground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
                        onDispose { lifecycle.removeObserver(observer);repository.foreground(false) }
                    }
                    MaterialTheme { Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                        Button(onClick={ state?.let { value ->
                            if(photos) { if(repository.beginPick(value.id)) launcher.launch(ActivityResultContracts.PickMultipleVisualMedia(2).createIntent(context,androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)).setComponent(external).putExtra("targetUid",android.os.Process.myUid())) }
                            else if(camera) repository.takePicture(value.id) { uri -> output=uri;launcher.launch(AvatarCameraContract().createIntent(context,uri).setComponent(external).putExtra("targetUid",android.os.Process.myUid())) }
                            else if(repository.beginDocument(value.id)) launcher.launch(ActivityResultContracts.OpenDocument().createIntent(context,arrayOf("*/*")).setComponent(external).putExtra("targetUid",android.os.Process.myUid()))
                        } },enabled=state?.draft!=null) { Text("选择测试附件") }
                        Spacer(Modifier.weight(1f))
                        ChatComposerBar(room,state,true,{ id,text->repository.edit(id,text) },{repository.beginPick(it)},{ id,uri->repository.picked(id,uri) },{repository.pickerFailed(it)},{id,asset->repository.remove(id,asset)},{repository.send(it)},{repository.retry(it)})
                    } }
                }
            }
            compose.waitUntil(5000) { state?.draft!=null };compose.onNodeWithText("选择测试附件").performClick()
            compose.waitUntil(15000) { (state?.attachments?.size==(if(photos) 2 else 1) && state?.preparing==false && (!photos || state?.thumbnails?.size==2)) || result?.hasExtra("failure")==true }
            assertNull(result?.getStringExtra("failure"));assertTrue(result?.getBooleanExtra("isolated",false)==true)
            val attachments=state!!.attachments;val attachment=attachments.first();assertEquals(if(camera || photos) "image/jpeg" else "text/plain",attachment.contentType)
            if(photos) runBlocking {
                for((index,item) in attachments.withIndex()) files.withOriginal(selection=item.asset) { file ->
                    val bitmap=android.graphics.BitmapFactory.decodeFile(file.path)
                    try { val color=bitmap.getPixel(0,0);assertTrue(if(index==0) android.graphics.Color.red(color)>240 && android.graphics.Color.blue(color)<15 else android.graphics.Color.blue(color)>240 && android.graphics.Color.red(color)<15) }
                    finally { bitmap.recycle() }
                }
            }
            else if(camera) assertFalse(File(context.cacheDir,"camera-captures-v1/${output!!.lastPathSegment}").exists())
            else {
                assertEquals(android.content.pm.PackageManager.PERMISSION_DENIED,context.checkUriPermission(requireNotNull(result?.data),android.os.Process.myPid(),android.os.Process.myUid(),Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
                runBlocking { files.withOriginal(selection=attachment.asset) { assertEquals("系统文件选择结果",it.readText()) } }
            }
            compose.onNodeWithContentDescription("发送").performClick();compose.waitUntil(5000) { state?.attachments?.isEmpty()==true && state?.sending==false }
            runBlocking { assertEquals(attachments,store.sendIntents().single().intent.attachments);assertTrue(store.conversationDraft(room).empty) }
        } finally { runBlocking { owner?.close();files.close() };store.close() }
    }
}
