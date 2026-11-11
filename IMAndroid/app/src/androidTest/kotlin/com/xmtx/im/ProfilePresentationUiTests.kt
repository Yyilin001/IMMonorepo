package com.xmtx.im

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ProfilePresentationUiTests {
    @get:Rule val compose = createComposeRule()
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val peer = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val device = DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");private val room = RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    private fun reader() = ProfilePresentationReading { keys -> keys.map { key -> ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(key.user,PublicIdentity(key.user,PublicHandle("friend"),"授权好友",AccountKind.Regular),null,ProfileState.Active,2,1),
            ProfileLease(actor,device,key,2,1,if(key.context != ProfileContext.Relationship) 1 else 0,ProfileAuthority(1,if(key.context != ProfileContext.Relationship) room else null,if(key.context != ProfileContext.Relationship) 1 else 0,0),0,300000)),System.nanoTime()+60000000000)
    }.toPersistentList() }
    @Test fun profileClearsOnPageExitAndRefreshesWithNewSyncGeneration() {
        var active by mutableStateOf(true);var generation by mutableStateOf("one");var opened = 0;var closed = 0
        compose.setContent {
            val scope = rememberCoroutineScope();val key = ProfileKey(peer,ProfileContext.Relationship)
            val profiles = rememberProfilePresentation(persistentListOf(key),generation,active,actor) {
                opened++;ProfilePresentationPage(actor,device,reader(),{ keys -> ProfileFenceSnapshot(generation,keys.associateWith { ProfileFence() }.toPersistentMap()) },scope,onClose = { closed++ })
            }
            MaterialTheme { Text(profiles.name(peer,ProfileContext.Relationship)) }
        }
        compose.waitUntil { compose.onAllNodesWithText("授权好友").fetchSemanticsNodes().isNotEmpty() }
        compose.runOnIdle { active = false };compose.onNodeWithText("授权好友").assertDoesNotExist();compose.onNodeWithText("资料暂不可用").assertIsDisplayed()
        compose.runOnIdle { assertEquals(1,closed);active = true;generation = "two" }
        compose.waitUntil { compose.onAllNodesWithText("授权好友").fetchSemanticsNodes().isNotEmpty() };compose.runOnIdle { assertEquals(2,opened) }
    }
    @Test fun readersResolveOnlyVisibleMembersUnderRoomContext() {
        val message = MessageId(actor.value);val calls = mutableListOf<ProfileKey>();var active by mutableStateOf(true)
        val state = AppState(session=SessionUi.SignedIn(actor),snapshot = ClientSnapshot(presentationGeneration = "one",messages = persistentListOf(Message(message,room,actor,"消息",1000,roomSequence = 1))))
        compose.setContent {
            val scope = rememberCoroutineScope()
            MaterialTheme { ReadReadersScreen(room,message,state,SessionUi.SignedIn(actor),active,openProfiles = {
                ProfilePresentationPage(actor,device,ProfilePresentationReading { keys -> calls.addAll(keys);reader().read(keys) },
                    { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },scope)
            },openSources={MessageSourceSession(messageSourceFixture(actor,state.snapshot.messages.single()),room,actor,scope)},fetch = { _,_,_->ReadReadersPage(room,message,persistentListOf(peer),null) }) }
        }
        compose.waitUntil { compose.onAllNodesWithText("授权好友").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(peer.value).assertDoesNotExist();compose.runOnIdle { assertEquals(listOf(ProfileKey(peer,ProfileContext.Room(room))),calls);active = false }
        compose.onNodeWithText("授权好友").assertDoesNotExist()
    }
    @Test fun conversationLabelsUseDirectAuthorityAndNeverFallBackToOldCachedName() {
        var active by mutableStateOf(true);val calls = mutableListOf<ProfileKey>()
        val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(presentationGeneration = "one",conversations = persistentListOf(Conversation(room,"旧缓存姓名",peer = peer))))
        compose.setContent {
            val scope = rememberCoroutineScope()
            MaterialTheme { Conversations(state,SessionUi.SignedIn(actor),active,{
                ProfilePresentationPage(actor,device,ProfilePresentationReading { keys -> calls.addAll(keys);reader().read(keys) },
                    { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },scope)
            },{}) }
        }
        compose.waitUntil { compose.onAllNodesWithText("授权好友").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("旧缓存姓名").assertDoesNotExist()
        compose.runOnIdle { assertEquals(listOf(ProfileKey(peer,ProfileContext.DirectConversation)),calls);active = false }
        compose.onNodeWithText("授权好友").assertDoesNotExist();compose.onNodeWithText("会话").assertIsDisplayed()
    }
    @Test fun directMessageAuthorsUseRoomAuthorityAndExcludeUnrelatedSender() {
        var active by mutableStateOf(true);val calls = mutableListOf<ProfileKey>();val outsider = UserId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
        val state = AppState(session = SessionUi.SignedIn(actor),snapshot = ClientSnapshot(presentationGeneration = "one",conversations = persistentListOf(Conversation(room,"会话",peer = peer)),
            messages = persistentListOf(Message(MessageId(actor.value),room,peer,"第一条",1000),Message(MessageId(device.value),room,outsider,"另一条",1001))))
        compose.setContent {
            val scope = rememberCoroutineScope()
            MaterialTheme { Chat(state,SessionUi.SignedIn(actor),room,{ _,_->true },active = active,openProfiles = {
                ProfilePresentationPage(actor,device,ProfilePresentationReading { keys -> calls.addAll(keys);reader().read(keys) },
                    { keys -> ProfileFenceSnapshot("one",keys.associateWith { ProfileFence() }.toPersistentMap()) },scope)
            }) }
        }
        compose.waitUntil { compose.onAllNodesWithText("授权好友").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(peer.value.take(20)).assertDoesNotExist();compose.onNodeWithText(outsider.value.take(20)).assertDoesNotExist()
        compose.runOnIdle { assertTrue(calls.isNotEmpty());assertTrue(calls.all { it == ProfileKey(peer,ProfileContext.Room(room)) });active = false }
        compose.onNodeWithText("授权好友").assertDoesNotExist()
    }
}
