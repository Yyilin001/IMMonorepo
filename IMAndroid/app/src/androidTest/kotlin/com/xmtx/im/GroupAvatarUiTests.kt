package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.PhotoPreparation
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class GroupAvatarUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val device=DeviceId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val room=RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");private val operation="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private fun app()=AppState(session=SessionUi.SignedIn(actor))
    private fun editor()=GroupAvatarEditorState("editor",room,revision=1,canManage=true,maximumBytes=1000000,deadlineNanos=System.nanoTime()+60000000000,hasAvatar=true)
    private fun photo()=runBlocking {
        val image=Bitmap.createBitmap(180,120,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try { image.eraseColor(android.graphics.Color.rgb(40,110,120));image.compress(Bitmap.CompressFormat.PNG,100,bytes) } finally { image.recycle() }
        PhotoPreparation().prepare(bytes.toByteString())
    }
    @Test fun chatSourceEntryRequiresManagementButDoesNotRequireLocalUploadCapabilities() {
        var state by mutableStateOf(editor().copy(maximumBytes=null));var opened=0
        compose.setContent {MaterialTheme {GroupAvatarScreen(app(),state,true,null,{},{},{},{},{},{_,_->},chatImages={opened++})}}
        compose.onNodeWithText("从相册选择").assertIsNotEnabled();compose.onNodeWithTag("group-avatar-chat-images").assertIsEnabled().performClick()
        compose.runOnIdle {assertEquals(1,opened);state=state.copy(canManage=false)}
        compose.onNodeWithTag("group-avatar-chat-images").assertIsNotEnabled()
        compose.runOnIdle {state=editor().copy(photo=photo())}
        compose.onNodeWithTag("group-avatar-chat-images").assertIsNotEnabled()
    }
    @Test fun generationAndRouteChangesCloseOldDisplayActivationBeforeReopening() {
        val scope=kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob()+kotlinx.coroutines.Dispatchers.Main.immediate)
        val repository=GroupAvatarRepository(actor,device,{
            GroupAvatarPresentation(actor,device,GroupAvatarState(room,null,0),1,null,true,null,1000,61000,1000,System.nanoTime()+60000000000,null)
        },{GroupAvatarFence("epoch",0,1,true)},scope)
        val pages=mutableListOf<GroupAvatarPage>();var active by mutableStateOf(true);var generation by mutableStateOf("first")
        try {
            compose.setContent { MaterialTheme {
                val display=rememberGroupAvatar(room,generation,active) { GroupAvatarPage(it,repository,{error("empty avatar must not download")},scope).also(pages::add) }
                androidx.compose.material3.Text(if(display.loading) "读取中" else "已就绪")
            } }
            compose.waitUntil(5000) { pages.size==1 };compose.waitForIdle()
            compose.runOnIdle { generation="next" }
            compose.waitUntil(5000) { pages.size==2 };compose.runOnIdle { assertTrue(pages[0].isClosed);active=false }
            compose.waitUntil(5000) { pages[1].isClosed };compose.runOnIdle { active=true }
            compose.waitUntil(5000) { pages.size==3 };compose.runOnIdle { active=false }
            compose.waitUntil(5000) { pages[2].isClosed }
        } finally { runBlocking { pages.forEach { it.awaitClosed() };repository.close() };scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }
    }
    @Test fun currentImageAndRemovalRequireActiveAuthorityAndLeavingPageCancelsConfirmation() {
        var active by mutableStateOf(true);var removed=0;val state=editor();val photo=photo()
        val pixels=AvatarPresentationBytes(AvatarContent(operation,"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",1,ResourceChecksum(java.security.MessageDigest.getInstance("SHA-256").digest(photo.data.toByteArray()).joinToString("") { "%02x".format(it) }),photo.data.size().toLong()),photo.data,System.nanoTime()+60000000000)
        compose.setContent { MaterialTheme { GroupAvatarScreen(app(),state,active,pixels,{},{},{},{},{removed++},{_,_->}) } }
        compose.waitUntil(5000) { compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("从相册选择").assertIsEnabled()
        if(InstrumentationRegistry.getArguments().getString("captureGroupAvatar")=="true") {
            InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput("group-avatar.png",0).use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it) }
        }
        compose.onNodeWithText("移除群头像").performScrollTo().performClick();compose.onNodeWithText("确认移除").assertIsDisplayed()
        compose.runOnIdle { active=false };compose.onNodeWithText("确认移除").assertDoesNotExist();compose.onNodeWithText("从相册选择").assertIsNotEnabled()
        compose.onAllNodesWithTag("avatar-image",useUnmergedTree=true).assertCountEquals(0)
        compose.runOnIdle { active=true };compose.onNodeWithText("移除群头像").performClick();compose.onNodeWithText("确认移除").performClick();compose.runOnIdle { assertEquals(1,removed) }
    }
    @Test fun unknownOutcomeCannotBeReplacedAndClosedTaskRequiresExplicitAbandonment() {
        val command=GroupAvatarCommand(operation,room,0,GroupAvatarMutation.Remove)
        var intent=GroupAvatarIntent(actor,device,command,0,stage=GroupAvatarStage.NeedsAttention,submissionStarted=true)
        var state by mutableStateOf(app().let { it.copy(snapshot=it.snapshot.copy(groupAvatarIntents=persistentListOf(intent))) })
        var acted:GroupAvatarTaskAction?=null
        compose.setContent { MaterialTheme { GroupAvatarScreen(state,editor(),true,null,{},{},{},{},{},{_,a->acted=a}) } }
        compose.onNodeWithText("从相册选择").assertIsNotEnabled();compose.onNodeWithText("按当前群头像重新尝试").assertDoesNotExist();compose.onNodeWithText("取消这次更改").assertDoesNotExist()
        compose.runOnIdle {
            intent=intent.copy(stage=GroupAvatarStage.Closed,proof=GroupAvatarClosureProof(actor,device,GroupAvatarRecoveryRequest(command,GroupAvatarRecoveryAction.CloseIfAbsent)))
            state=state.copy(snapshot=state.snapshot.copy(groupAvatarIntents=persistentListOf(intent)))
        }
        compose.onNodeWithText("按当前群头像重新尝试").performScrollTo().performClick();compose.runOnIdle { assertEquals(GroupAvatarTaskAction.Replace,acted);acted=null }
        compose.onNodeWithText("取消这次更改").performScrollTo().performClick();compose.runOnIdle { assertNull(acted) }
        compose.onNodeWithText("确认取消").performClick();compose.runOnIdle { assertEquals(GroupAvatarTaskAction.Abandon,acted) }
    }
    @Test fun cropKeepsPositionButRevokedRoomCannotSave() {
        val image=photo();var state by mutableStateOf(app());var editor by mutableStateOf(editor().copy(photo=image));var saved=0
        compose.setContent { MaterialTheme { GroupAvatarCropScreen(state,editor,true,{editor=editor.copy(crop=it.constrained(image.dimensions))},{saved++},{}) } }
        compose.onNodeWithTag("group-avatar-crop-zoom").performScrollTo().performSemanticsAction(SemanticsActions.SetProgress) { it(2f) }
        compose.onNodeWithText("使用这张群头像").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(1,saved);assertEquals(2f,editor.crop.zoom);state=state.copy(snapshot=state.snapshot.copy(revokedRooms=kotlinx.collections.immutable.persistentSetOf(room))) }
        compose.onNodeWithText("使用这张群头像").assertIsNotEnabled()
    }
}
