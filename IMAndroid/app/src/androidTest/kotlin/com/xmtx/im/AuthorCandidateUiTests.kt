package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@OptIn(ExperimentalTestApi::class,ExperimentalCoroutinesApi::class)
class AuthorCandidateUiTests {
    @get:Rule val compose=createComposeRule(effectContext=StandardTestDispatcher())
    @Test fun earlyAuthorAppearsWhenMessageRowBecomesVisibleWithoutHttpOrStagingReceipt() {
        val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");val peer=UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        val device=DeviceId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC");val room=RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
        val parent=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val receiver=AuthorPresentationReceiver(actor,device);val incoming=Channel<ReceivedAuthorPresentationDelta>(Channel.UNLIMITED)
        val view=AtomicReference<AuthorPresentationView>();val ready=CompletableDeferred<Unit>()
        val receives=AtomicInteger();val receipts=AtomicInteger();val reads=AtomicInteger()
        val source=object: AuthorPresentationSource {
            override fun beginAuthorPresentationView(messageRooms: PersistentList<RoomId>)=receiver.begin("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",messageRooms).also(view::set)
            override fun endAuthorPresentationView(view: AuthorPresentationView) {receiver.end(view)}
            override suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView): ReceivedAuthorPresentationDelta {receives.incrementAndGet();return incoming.receive()}
        }
        val commands=object: AuthorPresentationCommands {
            override suspend fun start(value: AuthorPresentationStart) {}
            override suspend fun end(value: AuthorPresentationStart) {}
            override suspend fun interests(value: AuthorPresentationInterests) {ready.complete(Unit)}
            override suspend fun receipt(value: AuthorPresentationReceipt) {receipts.incrementAndGet()}
        }
        val coordinator=AuthorPresentationCoordinator(source,commands,parent)
        var active by mutableStateOf(true)
        var snapshot by mutableStateOf(ClientSnapshot(presentationGeneration="early",conversations=persistentListOf(Conversation(room,"会话",peer=peer))))
        try {
            compose.runOnIdle {coordinator.selectMessageRoom(room)}
            compose.setContent {
                MaterialTheme {Chat(AppState(session=SessionUi.SignedIn(actor),snapshot=snapshot),SessionUi.SignedIn(actor),room,{_,_->true},active=active,openProfiles={
                    ProfilePresentationPage(actor,device,{reads.incrementAndGet();awaitCancellation()},{ProfileFenceSnapshot("early",persistentMapOf())},parent,
                        onClose=coordinator::remove).also(coordinator::register)
                })}
            }
            compose.waitUntil(5000) {ready.isCompleted}
            val key=ProfileKey(peer,ProfileContext.Room(room));val value=ProfileReadResult.Available(
                AuthorizedProfile(ProfileView(peer,PublicIdentity(peer,PublicHandle("friend"),"早到作者",AccountKind.Regular),null,ProfileState.Active,1,1),
                    ProfileLease(actor,device,key,1,1,1,ProfileAuthority(1,room,1,1),0,300000)),System.nanoTime()+60_000_000_000)
            incoming.trySend(ReceivedAuthorPresentationDelta(view.get(),1,persistentListOf(ReceivedAuthorPresentationEntry.Available(value))))
            compose.waitUntil(5000) {receives.get()>=2}
            compose.onNodeWithText("早到作者").assertDoesNotExist();assertEquals(0,receipts.get());assertEquals(0,reads.get())
            compose.runOnIdle {snapshot=snapshot.copy(messages=persistentListOf(Message(MessageId(peer.value),room,peer,"随后出现的消息",1000)))}
            compose.waitUntil(5000) {compose.onAllNodesWithText("早到作者").fetchSemanticsNodes().isNotEmpty()}
            compose.onNode(hasText("早到作者") and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed()
            assertEquals(0,reads.get());assertEquals(0,receipts.get())
            compose.runOnIdle {active=false};compose.onNodeWithText("早到作者").assertDoesNotExist()
        } finally {
            compose.runOnIdle {active=false;coordinator.close()};compose.waitForIdle()
            runBlocking {coordinator.awaitClosed()};parent.cancel();receiver.close();incoming.cancel()
        }
    }
}
