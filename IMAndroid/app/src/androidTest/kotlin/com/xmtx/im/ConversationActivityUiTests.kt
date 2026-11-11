package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Rule
import org.junit.Test

class ConversationActivityUiTests {
    @get:Rule val compose = createComposeRule()
    private val room=RoomId("00000000-0000-0000-0000-000000000001");private val actor=UserId("00000000-0000-0000-0000-000000000002");private val peer=UserId("00000000-0000-0000-0000-000000000003")
    @Test fun directBannerPrioritizesTypingAndHidesUnknownExpiredOrInactiveState() {
        var state by mutableStateOf(ConversationActivityState(room,true,true))
        var active by mutableStateOf(true)
        compose.setContent { MaterialTheme { ConversationActivityBanner(state,room,active,false) } }
        compose.onNodeWithText("对方在线").assertIsDisplayed()
        compose.runOnIdle {state=state.copy(typing=persistentSetOf(peer))}
        compose.onNodeWithText("对方正在输入…").assertIsDisplayed().assert(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion,LiveRegionMode.Polite))
        compose.onNodeWithText("对方在线").assertDoesNotExist()
        compose.runOnIdle {active=false};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {active=true;state=state.copy(typing=persistentSetOf(),online=null)}
        compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {state=state.copy(online=false)};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
    }
    @Test fun groupCountsDoNotExposeRawIdentifiersAndWrongRoomOrUnconfirmedStateIsHidden() {
        var state by mutableStateOf(ConversationActivityState(room,true,true,persistentSetOf(peer,UserId("second"))))
        compose.setContent { MaterialTheme { Column { ConversationActivityBanner(state,room,true,true) } } }
        compose.onNodeWithText("2 人正在输入…").assertIsDisplayed()
        compose.onNodeWithText(peer.value,substring=true).assertDoesNotExist()
        compose.runOnIdle {state=state.copy(room=RoomId("different"))};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {state=state.copy(room=room,subscribed=false)};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {state=state.copy(subscribed=true,typing=persistentSetOf())};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
    }
    @Test fun actualChatHidesActivityForRevokedInactiveAndDemoScopes() {
        val signedIn=SessionUi.SignedIn(actor)
        var state by mutableStateOf(AppState(session=signedIn,snapshot=ClientSnapshot(
            conversations=persistentListOf(Conversation(room,"同事",peer=peer)),
            messages=persistentListOf(Message(MessageId("received"),room,peer,"周五的会议资料我整理好了。",1),
                Message(MessageId("sent"),room,actor,"好的，我看完后给你反馈。",2))),
            conversationActivity=ConversationActivityState(room,true,true,persistentSetOf(peer))))
        var active by mutableStateOf(true);var session by mutableStateOf(signedIn)
        compose.setContent { MaterialTheme { Chat(state,session,room,send={_,_->true},active=active) } }
        compose.onNodeWithText("对方正在输入…").assertIsDisplayed()
        if(InstrumentationRegistry.getArguments().getString("captureActivity")=="true") {
            val context=InstrumentationRegistry.getInstrumentation().targetContext
            context.openFileOutput("conversation-activity.png",0).use {compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)}
        }
        compose.runOnIdle {active=false};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {active=true;state=state.copy(snapshot=state.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.runOnIdle {state=state.copy(snapshot=state.snapshot.copy(revokedRooms=persistentSetOf()));session=signedIn.copy(demo=true)}
        compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
    }
}
