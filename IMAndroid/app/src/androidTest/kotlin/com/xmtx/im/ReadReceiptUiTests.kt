package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ReadReceiptUiTests {
    @get:Rule val compose = createComposeRule()
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val peer = UserId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");private val message = MessageId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    @Test fun onlyActiveVisibleChatReportsHumanReadAndPeerReceiptChangesDeliveryLabel() {
        var active by mutableStateOf(false);val reported = mutableListOf<Long>()
        var state by mutableStateOf(AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(
            readCheckpoints = persistentListOf(RoomReadCheckpoint(room,10,12)),conversations = persistentListOf(Conversation(room,"私聊")),messages = persistentListOf(Message(message,room,actor,"测试消息",1000,roomSequence = 7)),
            directReads = persistentListOf(DirectReadProjection(room,peer,7,1000,true,1,1)))))
        compose.setContent { MaterialTheme { Chat(state,SessionUi.SignedIn(actor),room,{ _,_->true },active = active,reportRead = { _,seq -> reported.add(seq) }) } }
        compose.onNodeWithText("已读").assertIsDisplayed();compose.runOnIdle { assertTrue(reported.isEmpty());active = true }
        compose.waitUntil { reported.any { it == 10L } }
        compose.runOnIdle { assertFalse(12L in reported);active = false;reported.clear();state = state.copy(snapshot = state.snapshot.copy(directReads = persistentListOf(),readCheckpoints = persistentListOf(RoomReadCheckpoint(room,12,12)))) }
        compose.onNodeWithText("已受理").assertIsDisplayed();compose.runOnIdle { assertTrue(reported.isEmpty()) }
    }
    @Test fun unknownReadCanStopTrackingAndRestoreOnlyOriginalIdentity() {
        val command = ReadCommand(actor,room,"10000000-0000-0000-0000-000000000001",7)
        var work by mutableStateOf(ReadWork(command,ReadStatus.NeedsAttention,submissionStarted = true,reconcile = true,reason = "currentUnavailable:permissionDenied"))
        var restored: String? = null
        compose.setContent { MaterialTheme { ReadHistoryPage(room,AppState(snapshot = ClientSnapshot(readOperations = persistentListOf(work))),{},
            { id -> assertEquals(command.operation,id);work = work.copy(status = ReadStatus.Archived,archivedAt = 1000) },{ restored = it }) } }
        compose.onNodeWithText("停止本机追踪").performClick();compose.onNodeWithText("已停止本机追踪，结果仍可能已记录").assertIsDisplayed()
        compose.onNodeWithText("重新查询原记录").performClick();compose.runOnIdle { assertEquals(command.operation,restored) }
    }
    @Test fun readerPagesRejectCrossPageDuplicatesAndClearWhenDetailLosesDemand() {
        var active by mutableStateOf(true);var calls = 0
        val state = AppState(session=SessionUi.SignedIn(actor),snapshot = ClientSnapshot(conversations = persistentListOf(Conversation(room,"群聊",kind = RoomKind.Group)),
            messages = persistentListOf(Message(message,room,actor,"群消息",1000,roomSequence = 7))))
        compose.setContent { val scope=rememberCoroutineScope();MaterialTheme { ReadReadersScreen(room,message,state,SessionUi.SignedIn(actor),active,
            openSources={MessageSourceSession(messageSourceFixture(actor,state.snapshot.messages.single()),room,actor,scope)}) { _,_,cursor ->
            calls++;ReadReadersPage(room,message,persistentListOf(peer),if(cursor == null) "next" else null)
        } } }
        compose.onNodeWithText("已加载 1 位已读成员").assertIsDisplayed();compose.onNodeWithText(peer.value).assertDoesNotExist()
        compose.onNodeWithText("加载更多已读成员").performClick();compose.onNodeWithText("无法读取已读详情，请刷新重试").assertIsDisplayed()
        compose.runOnIdle { assertEquals(2,calls);active = false }
        compose.onNodeWithText("当前无法查看此消息的已读详情").assertIsDisplayed();compose.onNodeWithText("已加载 1 位已读成员").assertDoesNotExist()
    }
}
