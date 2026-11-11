package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OwnProfileUiTests {
    @get:Rule val compose = createComposeRule()
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val op = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private fun profile(revision: Long = 3,name: String = "当前名称") = ProfileView(actor,PublicIdentity(actor,PublicHandle("own_account"),name,AccountKind.Regular),null,ProfileState.Active,revision,revision+2)
    @Test fun staleCacheCannotSaveAndRestoredDraftRequiresAnotherFreshRead() {
        val value = profile();val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(ownProfile = value))
        var available = false;val restoration = StateRestorationTester(compose);var saved: Pair<ProfileView,String>? = null
        restoration.setContent { MaterialTheme { OwnProfileScreen(state,true,{ if(available) value else null },{ base,name -> saved = base to name;true },{}, {false}, {}) } }
        compose.onNodeWithText("公开名称").performTextInput("新的公开名称");compose.onNodeWithText("保存公开名称").assertIsNotEnabled()
        compose.runOnIdle { available = true };compose.onNodeWithText("刷新资料").performClick();compose.onNodeWithText("保存公开名称").assertIsEnabled()
        compose.runOnIdle { available = false };restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("新的公开名称").assertExists();compose.onNodeWithText("保存公开名称").assertIsNotEnabled()
        compose.runOnIdle { available = true };compose.onNodeWithText("刷新资料").performClick();compose.onNodeWithText("保存公开名称").performClick()
        compose.runOnIdle { assertEquals(value to "新的公开名称",saved) }
    }
    @Test fun unknownOutcomeOnlyOffersRecoveryAndCannotCreateReplacement() {
        val value = profile();val work = OwnProfileWork(OwnProfileCommand(actor,op,3,OwnProfilePatch("原编辑"),1700000000000),OwnProfileStatus.NeedsAttention,submissionStarted = true,reconcile = true)
        val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(ownProfile = value,ownProfileOperations = persistentListOf(work)))
        var retried: String? = null;var active by mutableStateOf(true)
        compose.setContent { MaterialTheme { OwnProfileScreen(state,active,{ value },{ _,_->error("must not submit") },{ retried = it },{ error("must not replace") },{ error("must not discard") }) } }
        compose.onNodeWithText("保存公开名称").assertIsNotEnabled();compose.onNodeWithText("按最新资料重新保存").assertDoesNotExist();compose.onNodeWithText("放弃这份草稿").assertDoesNotExist()
        compose.onNodeWithText("继续核对").performClick();compose.runOnIdle { assertEquals(op,retried);active = false }
        compose.onNodeWithText("继续核对").assertIsNotEnabled()
    }
    @Test fun completedOldEditDoesNotReplaceNewCurrentNameAndConflictRequiresExplicitReapply() {
        val value = profile(6,"另一设备的新名称");val command = OwnProfileCommand(actor,op,3,OwnProfilePatch("旧编辑"),1700000000000)
        var state by mutableStateOf(AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(ownProfile = value,ownProfileOperations = persistentListOf(OwnProfileWork(command,OwnProfileStatus.Committed,draftRetained = false)))))
        var reapplied: String? = null
        compose.setContent { MaterialTheme { OwnProfileScreen(state,true,{ value },{ _,_->true },{}, { reapplied = it;true },{}) } }
        compose.onAllNodesWithText("另一设备的新名称").onFirst().assertExists();compose.onNodeWithText("公开名称：旧编辑").assertExists();compose.onNodeWithText("按最新资料重新保存").assertDoesNotExist()
        compose.runOnIdle { state = state.copy(snapshot = state.snapshot.copy(ownProfileOperations = persistentListOf(OwnProfileWork(command,OwnProfileStatus.Conflicted)))) }
        compose.onNodeWithText("按最新资料重新保存").performScrollTo().performClick();compose.runOnIdle { assertEquals(op,reapplied) }
    }
}
