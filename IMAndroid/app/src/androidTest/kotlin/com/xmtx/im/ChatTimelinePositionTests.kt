package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ChatTimelinePositionTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private fun message(index: Int)=Message(MessageId(UUID.randomUUID().toString()),room,actor,"历史消息 $index\n这是消息正文",index.toLong(),roomSequence=index.toLong())
    private val source=message(1)
    private val reply=message(31).copy(text="最后的回复",rich=MessageRichContent(replyTo=source.id))
    private fun initial()=(listOf(source)+(2..30).map(::message)+reply).toPersistentList()
    private fun state(messages: PersistentList<Message>)=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"历史测试")),messages=messages))
    private fun row(id: MessageId)=compose.onNodeWithTag("chat-row-${id.value}",useUnmergedTree=true)
    private fun focus() {
        compose.onNodeWithTag("reply-reference-${reply.id.value}").performClick()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed();row(source.id).assertIsDisplayed()
    }
    @Test fun replyFocusRetainsItsStableAnchorAcrossAppendAndPrependUntilExplicitReturn() {
        var messages by mutableStateOf(initial())
        compose.setContent {MaterialTheme {Chat(state(messages),SessionUi.SignedIn(actor),room,{_,_->true})}}
        focus()
        if(InstrumentationRegistry.getArguments().getString("captureTimeline")=="true") {
            InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput("timeline-history-focus.png",0).use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
            }
        }
        val before=row(source.id).fetchSemanticsNode().boundsInRoot.top
        val incoming=message(32)
        compose.runOnIdle {messages=messages.add(incoming)}
        row(source.id).assertIsDisplayed();assertEquals(before,row(source.id).fetchSemanticsNode().boundsInRoot.top,1f)
        compose.runOnIdle {messages=persistentListOf(message(-2),message(-1)).addAll(messages)}
        row(source.id).assertIsDisplayed();assertEquals(before,row(source.id).fetchSemanticsNode().boundsInRoot.top,1f)
        compose.onNodeWithTag("chat-return-latest").performClick();row(incoming.id).assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertDoesNotExist()
        val next=message(33);compose.runOnIdle {messages=messages.add(next)};row(next.id).assertIsDisplayed()
    }
    @Test fun actualUserScrollStopsTailFollowingAndNewMessagesKeepReadingPosition() {
        var messages by mutableStateOf(initial())
        compose.setContent {MaterialTheme {Chat(state(messages),SessionUi.SignedIn(actor),room,{_,_->true})}}
        row(reply.id).assertIsDisplayed()
        compose.onNodeWithTag("chat-timeline").performTouchInput {swipeDown(durationMillis=500)}
        compose.onNodeWithTag("chat-return-latest").assertIsDisplayed()
        compose.mainClock.advanceTimeBy(2_000);compose.waitForIdle()
        val anchor=messages.first {m -> runCatching {row(m.id).assertIsDisplayed()}.isSuccess}
        row(anchor.id).assertIsDisplayed()
        val before=row(anchor.id).fetchSemanticsNode().boundsInRoot.top
        compose.runOnIdle {messages=messages.add(message(32))}
        row(anchor.id).assertIsDisplayed();assertEquals(before,row(anchor.id).fetchSemanticsNode().boundsInRoot.top,1f)
    }
    @Test fun historyFocusRestoresByIdentityAndInactiveUpdatesDoNotStealIt() {
        val restoration=StateRestorationTester(compose);var messages by mutableStateOf(initial());var active by mutableStateOf(true)
        restoration.setContent {MaterialTheme {Chat(state(messages),SessionUi.SignedIn(actor),room,{_,_->true},active=active)}}
        focus();restoration.emulateSavedInstanceStateRestore();row(source.id).assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
        compose.runOnIdle {active=false;messages=messages.add(message(32))}
        compose.onNodeWithTag("chat-return-latest").assertIsNotEnabled()
        compose.runOnIdle {active=true};row(source.id).assertIsDisplayed()
        compose.onNodeWithTag("chat-return-latest").performClick();row(messages.last().id).assertIsDisplayed()
    }
    @Test fun withdrawalClearsFocusedReferenceWithoutJumpingToLatest() {
        var messages by mutableStateOf(initial())
        compose.setContent {MaterialTheme {Chat(state(messages),SessionUi.SignedIn(actor),room,{_,_->true})}}
        focus();compose.runOnIdle {messages=messages.set(0,source.copy(withdrawn=true,revision=2))}
        compose.onNodeWithTag("chat-focused-message").assertDoesNotExist()
        compose.onNodeWithText("这条消息已撤回。").assertIsDisplayed()
        row(source.id).assertIsDisplayed();compose.onNodeWithTag("chat-return-latest").assertIsDisplayed()
    }
    @Test fun explicitSendFollowsTailButPendingAndAcceptedUpdatesDoNotInterruptHistory() {
        var messages by mutableStateOf(initial())
        val sent=message(34).copy(text="用户发送",delivery=Delivery.Pending,revision=0)
        var keyboard:androidx.compose.ui.platform.SoftwareKeyboardController?=null
        var imeBottom by mutableIntStateOf(0)
        compose.setContent {
            keyboard=LocalSoftwareKeyboardController.current;imeBottom=WindowInsets.ime.getBottom(LocalDensity.current)
            MaterialTheme {Chat(state(messages),SessionUi.SignedIn(actor),room,{_,_->messages=messages.add(sent);true})}
        }
        focus();val accepted=message(32);compose.runOnIdle {messages=messages.add(accepted)};row(source.id).assertIsDisplayed()
        val pending=message(33).copy(delivery=Delivery.Pending,revision=0)
        compose.runOnIdle {messages=messages.add(pending)};row(source.id).assertIsDisplayed()
        compose.runOnIdle {messages=messages.set(messages.lastIndex,pending.copy(id=MessageId(UUID.randomUUID().toString()),delivery=Delivery.Accepted))}
        row(source.id).assertIsDisplayed()
        compose.onNodeWithText("发送消息…").performTextInput("用户发送")
        compose.runOnIdle {keyboard?.hide()}
        compose.waitUntil(5000) {imeBottom==0}
        compose.onNodeWithContentDescription("发送").performClick()
        try {compose.waitUntil(5000) {runCatching {row(sent.id).assertIsDisplayed();true}.getOrDefault(false)}}
        catch(error:Throwable) {
            InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput("timeline-send-failure.png",0).use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
            }
            throw AssertionError("Sent admitted=${messages.any {it.id==sent.id}}, rows=${messages.size}, returnLatest=${compose.onAllNodesWithTag("chat-return-latest").fetchSemanticsNodes().size}",error)
        }
        row(sent.id).assertIsDisplayed()
        compose.onNodeWithTag("chat-return-latest").assertDoesNotExist();compose.onNodeWithTag("chat-focused-message").assertDoesNotExist()
    }
}
