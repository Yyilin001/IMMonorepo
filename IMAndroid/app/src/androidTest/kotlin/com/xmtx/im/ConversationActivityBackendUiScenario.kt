package com.xmtx.im

import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.Heartbeat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import org.junit.Assert.*
import java.util.concurrent.atomic.AtomicInteger

/** Both sides use the real gateway. Only the peer is driven by SDK calls; all App changes use its UI/lifecycle. */
internal fun verifyConversationActivityBackendUi(compose: ComposeContentTestRule,model: ()->AppViewModel,
    room: RoomId,actor: UserId,peer: UserId,peerSocket: RealtimeConnection,preview: String,
    hideKeyboard: ()->Unit,background: ()->Unit,foreground: ()->Unit,phase: (String)->Unit) {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    val positiveTyping=AtomicInteger();val positivePresence=AtomicInteger()
    lateinit var observer: ConversationActivitySession
    var observerInitialized=false
    val interest=ConversationActivityInterest(room,actor,onlineAllowed=true,typingAllowed=true)
    val originalDraft=requireNotNull(model().state.value.chatComposer).text
    fun waitFor(predicate: ()->Boolean)=compose.waitUntil(45000,predicate)
    fun draft(text: String) {compose.onNodeWithTag("persistent-message-draft").performTextReplacement(text);hideKeyboard()}
    fun openPrivacy() {
        hideKeyboard();compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithText("我的",useUnmergedTree=true).performClick()
        compose.onNodeWithTag("account-list").performScrollToNode(hasText("隐私设置"));compose.onNodeWithText("隐私设置").performClick()
    }
    fun openChat() {
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithText("消息",useUnmergedTree=true).performClick()
        compose.onNodeWithTag("conversation-list").performScrollToNode(hasText(preview));compose.onNodeWithText(preview).performClick()
        waitFor {model().state.value.chatComposer?.let {it.room==room && !it.loading && it.available}==true}
    }
    fun changeSharing(title: String,online: Boolean,value: Boolean) {
        waitFor {model().state.value.snapshot.preferences.any {it.value.kind==PreferenceKind.LiveActivity} && !model().state.value.preferenceLoading}
        val toggle=compose.onNodeWithContentDescription(title)
        toggle.performScrollTo();waitFor {runCatching {toggle.assertIsEnabled();true}.getOrDefault(false)}
        if(value) toggle.assertIsOff() else toggle.assertIsOn()
        toggle.performClick()
        waitFor {model().state.value.snapshot.let { snapshot->
            snapshot.preferences.any {it.value.kind==PreferenceKind.LiveActivity && (if(online) it.value.first else it.value.second)==value} &&
                snapshot.preferenceOperations.none {it.patch.kind==PreferenceKind.LiveActivity && !it.terminal}
        }}
        if(value) toggle.assertIsOn() else toggle.assertIsOff()
    }
    fun capture(name: String) {
        if(InstrumentationRegistry.getArguments().getString("captureAppBackend")=="true")
            InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput(name,0).use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)
            }
    }
    try {
        phase("real peer subscribes and observes App presence and restored draft")
        compose.runOnUiThread {
            scope.launch(start=CoroutineStart.UNDISPATCHED) {peerSocket.activityEvents.collect {event->
                when(val hint=event.hint) {
                    is LiveActivityHint.Typing->if(hint.value.room==room && hint.value.user==actor && hint.value.typing) positiveTyping.incrementAndGet()
                    is LiveActivityHint.Presence->if(hint.value.room==room && hint.value.user==actor && hint.value.online) positivePresence.incrementAndGet()
                    else->Unit
                }
            }}
            observer=ConversationActivitySession(peer,peerSocket.state.value.epoch,LiveActivityClient(peerSocket),peerSocket.activityEvents,
                peerSocket.state,scope,{peerSocket.latestActivitySequence},peerSocket::close)
            observerInitialized=true
            observer.update(interest)
            scope.launch {while(isActive) {
                peerSocket.request(Envelope.newBuilder().setHeartbeat(Heartbeat.newBuilder().setClientTimeMs(System.currentTimeMillis())))
                delay(5000)
            }}
        }
        waitFor {observer.state.value.let {it.subscribed && it.online==true && actor in it.typing}}
        waitFor {model().state.value.conversationActivity.online==true}
        compose.onNodeWithTag("conversation-activity").assertTextEquals("对方在线")
        phase("incoming typing is displayed in the actual chat and stops on peer clear")
        compose.runOnUiThread {observer.update(interest.copy(hasDraft=true))}
        waitFor {model().state.value.conversationActivity.typing.contains(peer)}
        compose.onNodeWithTag("conversation-activity").assertTextEquals("对方正在输入…");capture("app-backend-typing.png")
        compose.runOnUiThread {observer.update(interest)}
        waitFor {model().state.value.conversationActivity.typing.isEmpty()}
        compose.onNodeWithTag("conversation-activity").assertTextEquals("对方在线")
        phase("clearing the UI draft stops publication; editing restarts it")
        draft("");waitFor {observer.state.value.typing.isEmpty()}
        draft(originalDraft);waitFor {actor in observer.state.value.typing}
        phase("shared detail navigation stops typing and returns to the same draft")
        compose.onNodeWithContentDescription("聊天设置").performClick()
        waitFor {observer.state.value.typing.isEmpty()};compose.onNodeWithTag("conversation-activity").assertDoesNotExist()
        compose.onNodeWithContentDescription("返回").performClick()
        waitFor {actor in observer.state.value.typing};compose.onNodeWithTag("persistent-message-draft").assertTextContains(originalDraft)
        phase("actual Activity stop closes publication and foreground restores the draft lease")
        background()
        try {
            waitFor {model().state.value.conversationActivity==ConversationActivityState()}
            waitFor {observer.state.value.online!=true && observer.state.value.typing.isEmpty()}
        } finally {foreground()}
        waitFor {observer.state.value.online==true && actor in observer.state.value.typing}
        compose.onNodeWithTag("persistent-message-draft").assertTextContains(originalDraft)
        phase("privacy UI disables both sharing channels on the real account")
        openPrivacy();changeSharing("分享在线状态",true,false);changeSharing("分享正在输入状态",false,false)
        waitFor {observer.state.value.online!=true && observer.state.value.typing.isEmpty()}
        capture("app-backend-activity-privacy.png")
        openChat();draft("隐私关闭后的草稿")
        waitFor {model().state.value.conversationActivity.subscribed}
        val beforeTyping=positiveTyping.get();val beforePresence=positivePresence.get()
        // Observe longer than a full four-second renewal; do not infer suppression merely from an empty UI.
        runBlocking {delay(6000)}
        assertEquals(beforeTyping,positiveTyping.get());assertEquals(beforePresence,positivePresence.get())
        assertTrue(peerSocket.state.value.connected);assertTrue(observer.state.value.subscribed)
        assertTrue(observer.state.value.typing.isEmpty());assertNotEquals(true,observer.state.value.online)
        phase("disabled typing sharing refuses that channel while authorized incoming presence stays usable")
        compose.runOnUiThread {observer.update(interest.copy(hasDraft=true))}
        waitFor {model().state.value.conversationActivity.online==true}
        runBlocking {delay(6000)}
        assertTrue(model().state.value.conversationActivity.typing.isEmpty())
        assertEquals("已连接",model().state.value.connection)
        compose.onNodeWithTag("conversation-activity").assertTextEquals("对方在线")
        compose.runOnUiThread {observer.update(interest)}
        phase("confirmed UI reenable restores publication without replacing the draft")
        openPrivacy();changeSharing("分享在线状态",true,true);changeSharing("分享正在输入状态",false,true)
        openChat();waitFor {observer.state.value.online==true && actor in observer.state.value.typing}
        compose.onNodeWithTag("persistent-message-draft").assertTextContains("隐私关闭后的草稿")
        draft(originalDraft)
    } finally {
        compose.runOnUiThread {if(observerInitialized) observer.close();scope.cancel()}
    }
}
