package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NameEditorUiTests {
    @get:Rule val compose = createComposeRule()
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val target = NameTarget.Contact(UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    @Test fun restoredEditorKeepsDraftButRequiresFreshBaselineAndNav3TargetRoundTrips() {
        val route: Route = Route.NameEditor(target)
        assertEquals(route,Json.decodeFromString<Route>(Json.encodeToString(route)))
        val groupRoute: Route = Route.NameEditor(NameTarget.Group(RoomId(actor.value)))
        assertEquals(groupRoute,Json.decodeFromString<Route>(Json.encodeToString(groupRoute)))
        val value = NameSnapshot(actor,target,"原备注",3)
        val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(nameSnapshots = persistentListOf(value)))
        var available = true;val restoration = StateRestorationTester(compose)
        restoration.setContent { MaterialTheme { NameEditorScreen(target,state,true,{ if(available) value else null },{ _,_->true },{}, {}) } }
        compose.onNodeWithText("私人备注").performTextReplacement("旋转后的草稿")
        compose.onNodeWithText("保存").assertIsEnabled()
        compose.runOnIdle { available = false };restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("旋转后的草稿").assertExists();compose.onNodeWithText("保存").assertIsNotEnabled()
    }
    @Test fun cachedBaselineCannotSaveUntilRefreshAndEditUsesOriginalRevision() {
        val cached = NameSnapshot(actor,target,"旧备注",2);val fresh = cached.copy(name = "当前备注",revision = 3)
        var state by mutableStateOf(AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(nameSnapshots = persistentListOf(cached))))
        var allow = false;var submitted: Pair<NameSnapshot,String?>? = null
        compose.setContent { MaterialTheme { NameEditorScreen(target,state,true,{ if(allow) { state = state.copy(snapshot = state.snapshot.copy(nameSnapshots = persistentListOf(fresh)));fresh } else null },
            { baseline,name -> submitted = baseline to name;true },{}, {}) } }
        compose.onNodeWithText("私人备注").performTextInput("新备注");compose.onNodeWithText("保存").assertIsNotEnabled()
        compose.runOnIdle { allow = true };compose.onNodeWithText("刷新当前名称").performClick()
        compose.waitUntil { compose.onAllNodes(hasText("保存") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("保存").performClick();compose.runOnIdle { assertEquals(fresh to "新备注",submitted) }
    }
    @Test fun pendingOperationBlocksAnotherSaveAndUncertainResultOffersRecovery() {
        val value = NameSnapshot(actor,target,"当前备注",3)
        val work = NameWork(NameCommand(actor,target,"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","待确认",3,1700000000000),NameStatus.NeedsAttention,submissionStarted = true,reconcile = true)
        val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(nameSnapshots = persistentListOf(value),nameOperations = persistentListOf(work)))
        var retried: String? = null;var closed: String? = null;var active by mutableStateOf(true)
        compose.setContent { MaterialTheme { NameEditorScreen(target,state,active,{ value },{ _,_->error("must not save") },{ retried = it },{ closed = it }) } }
        compose.onNodeWithText("私人备注").performTextReplacement("其他");compose.onNodeWithText("保存").assertIsNotEnabled()
        compose.onNodeWithText("继续核对").performClick();compose.onNodeWithText("关闭原操作").performClick()
        compose.runOnIdle { assertEquals(work.command.operation,retried);assertEquals(work.command.operation,closed);active = false }
        compose.onNodeWithText("继续核对").assertIsNotEnabled();compose.onNodeWithText("私人备注").assertIsNotEnabled()
    }
}
