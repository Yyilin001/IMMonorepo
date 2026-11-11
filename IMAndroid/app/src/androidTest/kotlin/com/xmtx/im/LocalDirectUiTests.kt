package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class LocalDirectUiTests {
    @get:Rule val compose = createComposeRule()
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val actor = UserId(id()); private val peer = UserId(id()); private val room = RoomId(id())
    private val work = DirectRoomWork.fresh(DirectRoomCommand.create(actor, peer, 1000),
        PublicIdentity(peer, PublicHandle("friend"), "本地朋友", AccountKind.Regular))
    private fun state(work: DirectRoomWork = this.work) = AppState(session = SessionUi.SignedIn(actor), snapshot = ClientSnapshot(directOperations = persistentListOf(work)))
    @Test fun failedSaveKeepsOneSubmissionIdentityAndDraftAcrossStateRestoration() {
        val restore = StateRestorationTester(compose); val calls = mutableListOf<LocalDirectMessage>()
        var accepted = false
        restore.setContent { MaterialTheme {
            LocalDirectScreen(work.command.operation, state(), true, { calls.add(it); accepted }, {}, { null }, { _, _ -> null }) { _, _ -> }
        } }
        compose.onNodeWithTag("local-direct-draft").performTextInput("  保存后才清空  ")
        compose.onNodeWithTag("local-direct-send").performClick()
        compose.onNodeWithText("重试保存").assertIsDisplayed(); compose.onNodeWithTag("local-direct-draft").assertIsNotEnabled()
        restore.emulateSavedInstanceStateRestore()
        compose.runOnIdle { accepted = true }
        compose.onNodeWithTag("local-direct-send").performClick()
        compose.runOnIdle { assertEquals(2, calls.size); assertEquals(calls[0], calls[1]) }
        compose.onNodeWithTag("local-direct-draft").assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
    }
    @Test fun completedRoomWaitsForLocalMessagesBeforePassingUnsentInputToNavigation() {
        var state by mutableStateOf(state()); var entered: String? = null; var destination: DirectConversationDestination? = null
        compose.setContent { MaterialTheme {
            LocalDirectScreen(work.command.operation, state, true, { true }, {}, { null }, { _, text -> entered = text; room }) { next, _ -> destination = next }
        } }
        compose.onNodeWithTag("local-direct-draft").performTextInput("继续编辑的草稿")
        compose.runOnIdle { state = state.copy(snapshot = state.snapshot.copy(
            directOperations = persistentListOf(work.copy(status = DirectWorkStatus.Opened, room = room)),
            localDirectMessages = persistentListOf(LocalDirectMessage.create(work.command.operation, "待交接", 1000)))) }
        compose.runOnIdle { assertNull(destination) }
        compose.runOnIdle { state = state.copy(snapshot = state.snapshot.copy(localDirectMessages = persistentListOf())) }
        compose.waitUntil(5000) { destination != null }
        assertEquals("继续编辑的草稿", entered); assertEquals(DirectConversationDestination.Room(room), destination)
    }
    @Test fun retryCarriesDraftWithoutSilentlySendingItAndInactivePageDoesNotNavigate() {
        var active by mutableStateOf(true); var state by mutableStateOf(state(work.copy(status = DirectWorkStatus.Closed)))
        val next = DirectConversationDestination.Pending(id()); var carried: String? = null; var enters = 0; var sends = 0
        compose.setContent { MaterialTheme {
            LocalDirectScreen(work.command.operation, state, active, { sends++; true }, {}, { next }, { _, _ -> enters++; room }) { destination, text -> assertEquals(next, destination); carried = text }
        } }
        compose.onNodeWithTag("local-direct-draft").performTextInput("仍是草稿")
        compose.onNodeWithTag("local-direct-retry").performClick()
        compose.runOnIdle { assertEquals("仍是草稿", carried); assertEquals(0, sends); active = false
            state = state.copy(snapshot = state.snapshot.copy(directOperations = persistentListOf(work.copy(status = DirectWorkStatus.Opened, room = room)))) }
        compose.onNodeWithTag("local-direct-send").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(0, enters) }
    }
}
