package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MessagePlaybackUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private fun message(f:PlaybackFixture)=Message(f.selection.location.message,f.selection.location.room,actor,"附件",1000,media=MessageMedia(persistentListOf(f.selection.media),persistentListOf(MessageMediaPresentation(f.selection.media,if(f.video) MessageMediaKind.Video else MessageMediaKind.Audio,f.read.descriptor.contentType,f.read.descriptor.byteCount,f.read.descriptor))))
    private fun app(f:PlaybackFixture,message: Message=message(f))=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(f.selection.location.room,"播放测试群",kind=RoomKind.Group)),messages=persistentListOf(message)))
    @Test fun actualVideoSurfaceRendersAndSeekPauseControlsDriveTheOwnedPlayer() {
        val f=PlaybackFixture(true);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        var state by mutableStateOf<MessagePlaybackState?>(null);lateinit var owner:MessagePlaybackController
        try {
            compose.runOnUiThread {owner=f.controller(scope) {state=it};owner.foreground(true)}
            compose.setContent {MaterialTheme {MessagePlaybackScreen(app(f),state,f.selection,true,{owner.renderPlayer()},owner::toggle,owner::seek,owner::retry,{},openSources=rememberMessageSourceFixture(actor,message(f)))}}
            compose.waitUntil(15000) {state?.ready==true && f.rendered};compose.onNodeWithTag("message-playback-video").assertIsDisplayed();assertFalse(state!!.playRequested)
            compose.onNodeWithText("播放").performClick();compose.waitUntil(5000) {state?.playing==true};compose.onNodeWithText("暂停").performClick();compose.waitUntil(5000) {state?.playRequested==false}
            compose.onNodeWithTag("message-playback-seek").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) {it(0.5f)}
            try {compose.waitUntil(5000) {state!!.positionMs in 3900..4200 && state!!.ready}} catch(error:Throwable) {throw AssertionError("Seek half: position=${state?.positionMs}, duration=${state?.durationMs}, ready=${state?.ready}, feedback=${state?.feedback}",error)}
            compose.onNodeWithText("后退 10 秒").assertIsEnabled().performClick()
            try {compose.waitUntil(5000) {state!!.positionMs==0L}} catch(error:Throwable) {throw AssertionError("Seek start: position=${state?.positionMs}, duration=${state?.durationMs}, ready=${state?.ready}, feedback=${state?.feedback}",error)}
            if(InstrumentationRegistry.getArguments().getString("capturePlayback")=="true") {
                compose.waitForIdle();val bitmap=f.instrumentation.uiAutomation.takeScreenshot()
                try {f.context.openFileOutput("message-video-playback.png",0).use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}} finally {bitmap.recycle()}
            }
            compose.runOnUiThread {owner.foreground(false)};compose.onNodeWithTag("message-playback-video").assertDoesNotExist();compose.onNodeWithTag("message-playback-toggle").assertIsNotEnabled()
        } finally {compose.runOnUiThread {owner.close()};runBlocking {owner.awaitClosed()};scope.cancel();f.close()}
    }
    @Test fun revocationRevisionAndWrongRouteDisableControlsBeforeAsyncReloadCompletes() {
        val f=PlaybackFixture();var app by mutableStateOf(app(f));var active by mutableStateOf(true)
        val state=MessagePlaybackState(f.selection,"fixture",true,f.read,System.nanoTime()+60_000_000_000,ready=true,seekable=true,durationMs=8000)
        try {
            compose.setContent {MaterialTheme {MessagePlaybackScreen(app,state,f.selection,active,{null},{},{},{},{},openSources=rememberMessageSourceFixture(actor,app.snapshot.messages.single()))}}
            compose.onNodeWithText("播放").assertIsEnabled();compose.runOnIdle {app=app(f,message(f).copy(revision=2))};compose.onNodeWithText("播放").assertIsNotEnabled()
            compose.runOnIdle {app=app(f,message(f).copy(withdrawn=true))};compose.onNodeWithText("文件操作").assertIsNotEnabled()
            compose.runOnIdle {app=app(f);active=false};compose.onNodeWithText("播放").assertIsNotEnabled();compose.onNodeWithText("文件操作").assertIsNotEnabled()
        } finally {f.close()}
    }
    @Test fun sharedNav3PlaybackRestoresOnlyIdsAndReturnsToTheDraft() {
        val f=PlaybackFixture();val model=AppViewModel(f.context.applicationContext as Application);val models=ViewModelStore().apply {put("playback",model)};val restore=StateRestorationTester(compose);val sourceApp=installMediaNavigationSource(model,app(f))
        try {
            restore.setContent {MaterialTheme {SignedIn(sourceApp,SessionUi.SignedIn(actor),model)}}
            compose.onNodeWithText("播放测试群").performClick();compose.waitUntil(5000) {compose.onAllNodesWithTag("message-playback-open-${f.selection.media}").fetchSemanticsNodes().isNotEmpty()};compose.onNodeWithText("发送消息…").performTextInput("播放后继续编辑")
            compose.onNodeWithTag("message-playback-open-${f.selection.media}").performClick();compose.onNodeWithText("播放附件").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("播放附件").assertIsDisplayed();compose.waitUntil(5000) {compose.onAllNodesWithText(f.read.descriptor.displayName).fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("文件操作").performClick();compose.onNodeWithText("查看文件").assertIsDisplayed();compose.waitUntil(5000) {compose.onAllNodesWithText("应用内播放").fetchSemanticsNodes().isNotEmpty()};compose.onNodeWithText("应用内播放").assertExists()
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("播放后继续编辑").assertIsDisplayed()
            val route:Route=Route.MessagePlayback(f.selection.location.room.value,f.selection.location.message.value,f.selection.media);val encoded=Json.encodeToString(route)
            assertEquals(route,Json.decodeFromString<Route>(encoded));assertFalse(encoded.contains("file:"));assertFalse(encoded.contains("deadline"));assertFalse(encoded.contains("position"))
        } finally {compose.runOnUiThread {models.clear()};awaitMediaNavigationClosed(model);f.close()}
    }
    @Test fun audioVideoRowsUsePlaybackWhileFilesAndImagesKeepTheirOwnActions() {
        val f=PlaybackFixture();var msg by mutableStateOf(message(f));var played=0;var files=0
        try {
            compose.setContent {MaterialTheme {MessageBubbleContent(msg,openFile={files++},openPlayback={played++})}}
            compose.onNodeWithTag("message-playback-open-${f.selection.media}").performClick();assertEquals(1,played);assertEquals(0,files)
            compose.runOnIdle {msg=msg.copy(delivery=Delivery.Pending)};compose.onNodeWithTag("message-playback-open-${f.selection.media}").assertDoesNotExist()
            compose.runOnIdle {msg=msg.copy(withdrawn=true)};compose.onNodeWithText(f.read.descriptor.displayName).assertDoesNotExist()
            assertEquals("1:02:03",playbackTime(3723000));assertEquals("0:00",playbackTime(-1))
        } finally {f.close()}
    }
}
