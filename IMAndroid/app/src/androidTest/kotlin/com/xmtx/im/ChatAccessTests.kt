package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentSetOf
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ChatAccessTests {
    @get:Rule val compose = createComposeRule()
    @Test fun revocationDisablesSendingWithoutDiscardingTheEditorDraft() {
        val room = RoomId("room")
        val session = SessionUi.SignedIn(UserId("me"))
        val snapshot = ClientSnapshot(conversations = persistentListOf(Conversation(room, "群聊", kind = RoomKind.Group)))
        val state = mutableStateOf(AppState(session = session, snapshot = snapshot))
        var sent: String? = null
        compose.setContent { MaterialTheme { Chat(state.value, session, room, send = { _, text -> sent = text; true }) } }
        compose.onNodeWithText("发送消息…").performTextInput("保留这个草稿")
        compose.runOnIdle { state.value = state.value.copy(snapshot = snapshot.copy(conversations = persistentListOf(), revokedRooms = persistentSetOf(room))) }
        compose.onNodeWithText("此会话已不可访问，无法发送消息").assertIsDisplayed()
        compose.onNodeWithText("保留这个草稿").assertIsNotEnabled()
        compose.onNodeWithContentDescription("发送").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(null, sent); state.value = state.value.copy(snapshot = snapshot) }
        compose.onNodeWithText("保留这个草稿").assertIsEnabled()
        compose.onNodeWithContentDescription("发送").performClick()
        compose.runOnIdle { assertEquals("保留这个草稿", sent) }
    }
}
