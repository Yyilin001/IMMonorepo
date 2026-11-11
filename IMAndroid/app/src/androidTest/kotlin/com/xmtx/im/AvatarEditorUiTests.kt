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

class AvatarEditorUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val id="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private val op="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private fun profile()=ProfileView(actor,PublicIdentity(actor,PublicHandle("avatar_owner"),"我的资料",AccountKind.Regular),id,ProfileState.Active,3,5)
    private fun app()=AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(ownProfile=profile()))
    private fun image()=runBlocking {
        val bitmap=Bitmap.createBitmap(600,400,Bitmap.Config.ARGB_8888);val out=ByteString.newOutput()
        try {
            val canvas=android.graphics.Canvas(bitmap);canvas.drawColor(android.graphics.Color.rgb(190,225,240))
            val paint=android.graphics.Paint().apply { color=android.graphics.Color.rgb(45,100,130) }
            canvas.drawCircle(300f,180f,100f,paint);paint.color=android.graphics.Color.rgb(235,180,100)
            canvas.drawRect(200f,280f,400f,400f,paint);bitmap.compress(Bitmap.CompressFormat.PNG,100,out)
        } finally { bitmap.recycle() }
        PhotoPreparation().prepare(out.toByteString())
    }
    @Test fun cropRequiresFreshBaselineAndKeepsExplicitPositionChanges() {
        val photo=image();var state by mutableStateOf(app());var editor by mutableStateOf(AvatarEditorState("editor",photo=photo))
        var saved=0
        fun reveal(matcher: SemanticsMatcher): SemanticsNodeInteraction {
            compose.onNode(hasScrollAction()).performScrollToNode(matcher)
            return compose.onNode(matcher)
        }
        compose.setContent { MaterialTheme { AvatarCropScreen(state,editor,true,{ editor=editor.copy(crop=it.constrained(photo.dimensions)) },{ saved++ },{ editor=editor.copy(baseline=state.snapshot.ownProfile) }) } }
        reveal(hasText("使用这张头像")).assertIsNotEnabled()
        reveal(hasText("刷新资料")).performClick()
        reveal(hasText("使用这张头像")).assertIsEnabled()
        reveal(hasTestTag("avatar-crop-zoom")).performSemanticsAction(SemanticsActions.SetProgress) { it(2f) }
        reveal(hasTestTag("avatar-crop-x")).performSemanticsAction(SemanticsActions.SetProgress) { it(0.7f) }
        compose.runOnIdle { assertEquals(2f,editor.crop.zoom);assertEquals(0.7f,editor.crop.x) }
        reveal(hasContentDescription("头像裁剪区域"))
        if(InstrumentationRegistry.getArguments().getString("captureAvatar")=="true") {
            val context=InstrumentationRegistry.getInstrumentation().targetContext
            context.openFileOutput("avatar-crop.png",0).use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it) }
        }
        reveal(hasText("使用这张头像")).performClick();compose.runOnIdle { assertEquals(1,saved);state=state.copy(snapshot=state.snapshot.copy(ownProfile=profile().copy(revision=4))) }
        compose.onNodeWithText("使用这张头像").assertIsNotEnabled()
    }
    @Test fun unknownOutcomeCannotBeReplacedOrDiscardedAndConflictNeedsExplicitAction() {
        val intent=ProfileIntent(id,actor,op,3,1700000000000,avatar=ProfileAvatarPatch.Remove,frozen=true)
        val work=OwnProfileWork(intent.command(),OwnProfileStatus.NeedsAttention,submissionStarted=true,reconcile=true)
        var state by mutableStateOf(app().let { it.copy(snapshot=it.snapshot.copy(profileIntents=persistentListOf(ProfileIntentStatus(intent,work,ProfileIntentPhase.NeedsAttention,false)))) })
        var resumed:String?=null;var discarded:String?=null
        compose.setContent { MaterialTheme { AvatarEditorScreen(state,AvatarEditorState("editor",baseline=profile()),true,{},{},{},{},{ resumed=it },{ discarded=it },{}) } }
        compose.onNodeWithText("从相册选择").assertIsNotEnabled()
        compose.onNodeWithText("按最新资料重新保存").assertDoesNotExist();compose.onNodeWithText("放弃这次修改").assertDoesNotExist()
        compose.onNodeWithText("继续处理").performScrollTo().performClick();compose.runOnIdle {
            assertEquals(id,resumed);state=state.copy(snapshot=state.snapshot.copy(profileIntents=persistentListOf(ProfileIntentStatus(intent,work.copy(status=OwnProfileStatus.Conflicted),ProfileIntentPhase.NeedsAttention,true))))
        }
        compose.onNodeWithText("按最新资料重新保存").performScrollTo().performClick()
        compose.onNodeWithText("放弃这次修改").performScrollTo().performClick();compose.runOnIdle { assertNull(discarded) }
        compose.onNodeWithText("确认放弃").performClick();compose.runOnIdle { assertEquals(id,discarded) }
    }
    @Test fun removalRequiresConfirmationAndLeavingActivePageCancelsIt() {
        var active by mutableStateOf(true);var removed=0
        compose.setContent { MaterialTheme { AvatarEditorScreen(app(),AvatarEditorState("editor",baseline=profile()),active,{},{},{},{ removed++ },{},{},{}) } }
        compose.onNodeWithText("移除头像").performScrollTo().performClick();compose.onNodeWithText("确认移除").assertIsDisplayed()
        compose.runOnIdle { active=false };compose.onNodeWithText("确认移除").assertDoesNotExist();compose.onNodeWithText("从相册选择").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(0,removed);active=true };compose.onNodeWithText("移除头像").performClick();compose.onNodeWithText("确认移除").performClick()
        compose.runOnIdle { assertEquals(1,removed) }
    }
    @Test fun importedAvatarTaskShowsRecoveryAndUsesImportSpecificDiscardConfirmation() {
        val source=ProfileAvatarImport(op,ResourceImportRequest(id,ResourceImportSource.Avatar(ProfileKey(actor,ProfileContext.Relationship),id,op),ResourceUsage.UserAvatar,actor.value))
        val intent=ProfileIntent(id,actor,op,3,1800000000000,preparation=ProfilePreparation.NeedsAttention,serverImport=source)
        val state=app().let { it.copy(snapshot=it.snapshot.copy(profileIntents=persistentListOf(ProfileIntentStatus(intent,null,ProfileIntentPhase.NeedsAttention,false)))) }
        var resumed:String?=null;var discarded:String?=null
        compose.setContent { MaterialTheme { AvatarEditorScreen(state,AvatarEditorState("editor",baseline=profile()),true,{},{},{},{},{ resumed=it },{ discarded=it },{}) } }
        compose.onNodeWithText("从相册选择").assertIsNotEnabled()
        compose.onNodeWithText("导入任务已保留，可继续恢复。").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("原图已保留，可继续恢复。").assertDoesNotExist()
        compose.onNodeWithText("继续处理").performScrollTo().performClick();compose.runOnIdle { assertEquals(id,resumed) }
        compose.onNodeWithText("放弃这次修改").performScrollTo().performClick()
        compose.onNodeWithText("将放弃这次头像修改，并停止使用这份导入结果。").assertIsDisplayed();compose.runOnIdle { assertNull(discarded) }
        compose.onNodeWithText("确认放弃").performClick();compose.runOnIdle { assertEquals(id,discarded) }
    }

}
