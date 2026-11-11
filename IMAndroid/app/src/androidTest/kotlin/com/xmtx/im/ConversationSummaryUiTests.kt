package com.xmtx.im

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ConversationSummaryUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private fun room(index: Int)=RoomId("00000000-0000-0000-0000-${index.toString().padStart(12,'0')}")
    @Test fun listRequestsOnlyVisibleRowsAndScrollingReplacesDemandWithoutReopeningOwner() {
        val rows=(1..100).map {Conversation(room(it),"房间 $it",kind=RoomKind.Group)}.toPersistentList()
        val session=SessionUi.SignedIn(actor);var demand=persistentListOf<RoomId>();var opened=0
        compose.setContent {MaterialTheme {Box(Modifier.height(240.dp)) {
            Conversations(AppState(session=session,snapshot=ClientSnapshot(conversations=rows)),session,true,{null},{},openSummaries={
                opened++;ConversationSummaryPage({demand=it},{demand=persistentListOf()})
            })
        }}}
        compose.waitUntil {demand.isNotEmpty()}
        compose.runOnIdle {assertTrue(demand.size<10);assertTrue(room(1) in demand);assertFalse(room(90) in demand);assertEquals(1,opened)}
        compose.onNodeWithTag("conversation-list").performScrollToNode(hasText("房间 90"))
        compose.waitUntil {room(90) in demand}
        compose.runOnIdle {assertFalse(room(1) in demand);assertTrue(demand.size<10);assertEquals(1,opened)}
    }
    @Test fun inactiveDemoAndRevokedScopesCannotRetainSummaryInterestAndOldPageCannotReviveIt() {
        var active by mutableStateOf(true);var session by mutableStateOf(SessionUi.SignedIn(actor))
        var revoked by mutableStateOf(persistentSetOf<RoomId>());var demand=persistentListOf<RoomId>();var opened=0;var closed=0;var old: ConversationSummaryPage?=null
        compose.setContent {MaterialTheme {
            Conversations(AppState(session=session,snapshot=ClientSnapshot(conversations=persistentListOf(Conversation(room(1),"群聊",kind=RoomKind.Group)),revokedRooms=revoked)),session,active,{null},{},openSummaries={
                opened++;ConversationSummaryPage({demand=it},{closed++;demand=persistentListOf()}).also {old=it}
            })
        }}
        compose.waitUntil {demand.isNotEmpty()}
        compose.runOnIdle {revoked=persistentSetOf(room(1))}
        compose.waitUntil {demand.isEmpty()}
        compose.runOnIdle {active=false}
        compose.runOnIdle {assertEquals(1,closed);old!!.update(persistentListOf(room(1)));assertTrue(demand.isEmpty());session=session.copy(demo=true);active=true;revoked=persistentSetOf()}
        compose.runOnIdle {assertEquals(1,opened);assertTrue(demand.isEmpty());session=session.copy(demo=false)}
        compose.waitUntil {demand.isNotEmpty()}
        compose.runOnIdle {assertEquals(2,opened)}
    }
    @Test fun archivedListRequestsItsOwnRowsAndDisposalClosesInterest() {
        var showing by mutableStateOf(true);var demand=persistentListOf<RoomId>();var closed=0
        val session=SessionUi.SignedIn(actor)
        val rows=persistentListOf(Conversation(room(1),"普通",kind=RoomKind.Group),Conversation(room(2),"归档",archived=true,kind=RoomKind.Group))
        compose.setContent {MaterialTheme {if(showing) Conversations(AppState(session=session,snapshot=ClientSnapshot(conversations=rows)),session,true,{null},{},archived=true,
            openSummaries={ConversationSummaryPage({demand=it},{closed++;demand=persistentListOf()})})}}
        compose.waitUntil {demand.isNotEmpty()}
        compose.runOnIdle {assertEquals(persistentListOf(room(2)),demand);showing=false}
        compose.runOnIdle {assertTrue(demand.isEmpty());assertEquals(1,closed)}
    }
    @Test fun backgroundAndAccountChangeCloseOldOwnerBeforeCreatingFreshInterest() {
        val owner=object: androidx.lifecycle.LifecycleOwner {
            val registry=androidx.lifecycle.LifecycleRegistry(this)
            override val lifecycle: androidx.lifecycle.Lifecycle get()=registry
        }
        var session by mutableStateOf(SessionUi.SignedIn(actor));var demand=persistentListOf<RoomId>();var opened=0;var closed=0
        val pages=mutableListOf<ConversationSummaryPage>()
        compose.runOnIdle {owner.registry.currentState=androidx.lifecycle.Lifecycle.State.RESUMED}
        compose.setContent {CompositionLocalProvider(androidx.lifecycle.compose.LocalLifecycleOwner provides owner) {MaterialTheme {
            Conversations(AppState(session=session,snapshot=ClientSnapshot(conversations=persistentListOf(Conversation(room(1),"群聊",kind=RoomKind.Group)))),session,true,{null},{},
                openSummaries={opened++;ConversationSummaryPage({demand=it},{closed++;demand=persistentListOf()}).also {pages+=it}})
        }}}
        compose.waitUntil {demand.isNotEmpty()}
        compose.runOnIdle {owner.registry.currentState=androidx.lifecycle.Lifecycle.State.CREATED}
        compose.waitUntil {closed==1 && demand.isEmpty()}
        compose.runOnIdle {owner.registry.currentState=androidx.lifecycle.Lifecycle.State.RESUMED}
        compose.waitUntil {opened==2 && demand.isNotEmpty()}
        compose.runOnIdle {session=SessionUi.SignedIn(UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))}
        compose.waitUntil {opened==3 && closed==2 && demand.isNotEmpty()}
        compose.runOnIdle {pages.first().update(persistentListOf(room(90)));pages.first().close();assertEquals(persistentListOf(room(1)),demand);assertEquals(2,closed)}
    }

}
