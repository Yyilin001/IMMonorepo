package com.xmtx.im

import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.sharedsdk.*
import com.xmtx.im.swiftplatform.AndroidRuntimePlatform
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.net.Socket
import java.util.UUID

/** Real App and an independent shared-SDK peer, with HTTPS-only isolated fixture setup. */
class SharedSDKMessagingBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun appMessagesOfflineQueueAndAccountIsolation() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base = requireNotNull(args.getString("sharedURL"))
        val port = requireNotNull(args.getString("sharedTLSPort")).toInt()
        val peerPort = requireNotNull(args.getString("sharedPeerTLSPort")).toInt()
        val control = requireNotNull(args.getString("sharedControlPort")).toInt()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(10)
        val password = UUID.randomUUID().toString() + "aA1!"
        val names = listOf("phase5_${run}_a", "phase5_${run}_b", "phase5_${run}_c")
        val fixture = SharedBackendFixture(base)
        var peer: SharedClient? = null
        var peerJob: Job? = null
        var scenario: ActivityScenario<MainActivity>? = null
        var reopened: SharedClient? = null
        var retainedWindow: SharedConversationWindow? = null
        val evidence = JSONObject().put("realBackend", true).put("appEntry", "MainActivity")
        fun command(value: String) = Socket("localhost", control).use { socket ->
            socket.soTimeout = 5000; socket.outputStream.write((value + "\n").toByteArray())
            assertEquals("OK", socket.inputStream.bufferedReader().readLine())
        }
        try {
            val accounts = names.map { name -> fixture.register(name, password) }
            val a = accounts[0]; val b = accounts[1]; val c = accounts[2]
            val sharedRoom = fixture.direct(b, a)
            val privateRoom = fixture.direct(a, c)
            // Distinct gateway port => distinct secure namespace; both use the real gateway.
            peer = SharedClient.open(context, SharedEndpoint(base, "localhost", peerPort))
            peer!!.login(names[1], password)
            peerJob = launch(Dispatchers.Default) { peer!!.foregroundStates().collect { } }
            withTimeout(45000) { while (peer!!.snapshot().conversations.none { it.id == sharedRoom }) delay(250) }
            // Directory entries can arrive before the local permission projection. Wait for
            // positive read authority rather than treating directory visibility as permission.
            withTimeout(45000) {
                while (true) {
                    try { peer!!.openConversation(sharedRoom); break }
                    catch (error: SharedSdkException) {
                        if (error.reason != SharedError.InvalidInput) throw error
                        delay(250)
                    }
                }
            }
            android.util.Log.i("SharedSDKAcceptance", "peer local read authority ready")
            val denied = runCatching { peer!!.openConversation(privateRoom) }.exceptionOrNull()
            assertEquals(SharedError.InvalidInput, (denied as? SharedSdkException)?.reason)
            assertEquals(sharedRoom, peer!!.snapshot().chat?.roomID)
            val incoming = "真实对端消息 $run"
            peer!!.sendText(sharedRoom, incoming)
            SharedAppSettings.save(context, SharedEndpoint(base, "localhost", port))
            var model: SharedAppViewModel? = null
            fun launchApp() {
                scenario = ActivityScenario.launch(MainActivity::class.java)
                scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }
                compose.waitUntil(20000) { model != null && !model!!.state.value.busy }
            }
            fun login(index: Int) {
                compose.onNodeWithTag("shared_account").performTextReplacement(names[index])
                compose.onNodeWithTag("shared_password").performTextInput(password)
                compose.onNodeWithTag("shared_login").performClick()
                compose.waitUntil(60000) { model!!.state.value.snapshot?.let { it.userID == accounts[index].userID && it.state == SharedSessionState.Connected } == true }
            }
            fun openRoom() {
                compose.waitUntil(45000) { model!!.state.value.snapshot?.conversations?.any { it.id == sharedRoom } == true }
                compose.onNodeWithTag("shared_room_${sharedRoom}").performClick()
                compose.waitUntil(15000) { model!!.state.value.snapshot?.chat?.roomID == sharedRoom && !model!!.state.value.busy }
            }
            fun waitMessage(text: String) {
                compose.waitUntil(60000) { model!!.state.value.snapshot?.chat?.messages?.any { it.text == text } == true }
                compose.onNodeWithTag("shared_messages").performScrollToNode(hasText(text))
                compose.onNodeWithText(text).assertIsDisplayed()
            }
            suspend fun peerReceives(text: String) {
                withTimeout(60000) {
                    while (peer!!.snapshot().chat?.messages?.none { it.text == text } != false) delay(250)
                }
                assertEquals(1, peer!!.snapshot().chat!!.messages.count { it.text == text })
            }
            launchApp()
            compose.onNodeWithTag("shared_account").performTextInput(names[0])
            compose.onNodeWithTag("shared_password").performTextInput("incorrect-password")
            compose.onNodeWithTag("shared_login").performClick()
            compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.error != null }
            assertNull(model!!.state.value.snapshot?.userID)
            login(0)
            compose.waitUntil(45000) { model!!.state.value.snapshot?.conversations?.any { it.id == privateRoom } == true }
            openRoom(); waitMessage(incoming)
            val outgoing = "共享 SDK 发出 $run"
            compose.onNodeWithTag("shared_composer").performTextInput(outgoing)
            compose.onNodeWithTag("shared_send").assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick) { it() }
            peerReceives(outgoing); waitMessage(outgoing)
            compose.waitUntil(15000) { model!!.state.value.snapshot?.chat?.pending?.none { it.text == outgoing } == true }
            evidence.put("incomingDisplayed", true).put("outgoingPeerCount", 1)
            // More cancellations than the 128-window capacity: abandoned successful opens
            // must be adopted and closed, including cancellation during dispatcher handoff.
            repeat(140) { index ->
                val opening = launch(Dispatchers.Default) {
                    val window = peer!!.openMessageTimeline(sharedRoom, pageSize = 1)
                    try { yield() } finally { window.close() }
                }
                delay((index % 3 + 1).toLong())
                opening.cancelAndJoin()
            }
            evidence.put("cancelledWindowOpensDrained", true)
            val listWindow = peer!!.openConversationList(pageSize = 1)
            assertTrue(listWindow.snapshot().conversations.any { it.id == sharedRoom })
            listWindow.close()
            val history = peer!!.openMessageTimeline(sharedRoom, pageSize = 1)
            val live = peer!!.openMessageTimeline(sharedRoom, pageSize = 20)
            retainedWindow = live
            val latestID = history.snapshot().chat!!.messages.single().id
            val older = history.nextPage().chat!!.messages.single().id
            assertNotEquals(latestID, older)
            assertTrue(live.snapshot().chat!!.messages.any { it.id == latestID })
            val historyObservation = launch { runCatching { history.states().collect { } } }
            val liveText = "独立窗口实时消息 $run"
            val liveObservation = async { withTimeout(45000) { live.states().first { value -> value.chat?.messages?.any { it.text == liveText } == true } } }
            peer!!.sendText(sharedRoom, liveText)
            assertEquals(older, history.snapshot().chat!!.messages.single().id)
            history.close(); historyObservation.cancelAndJoin()
            assertTrue(liveObservation.await().chat!!.messages.any { it.text == liveText })
            assertEquals(sharedRoom, peer!!.snapshot().chat?.roomID)
            evidence.put("independentWindowPaging", true).put("independentWindowObservation", true).put("closingWindowPreservesSibling", true)
            android.util.Log.i("SharedSDKAcceptance", "shared send and receive completed")
            command("pause")
            compose.waitUntil(20000) { model!!.state.value.snapshot?.state != SharedSessionState.Connected }
            val queued = "断线期间持久发送 $run"
            compose.onNodeWithTag("shared_composer").performTextInput(queued)
            compose.onNodeWithTag("shared_send").assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick) { it() }
            compose.waitUntil(15000) { model!!.state.value.snapshot?.chat?.pending?.any { it.text == queued } == true }
            // Close the complete App owner while offline. The next owner must recover the same send.
            scenario!!.close(); scenario = null
            withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            launchApp()
            compose.waitUntil(20000) { model!!.state.value.snapshot?.userID == a.userID }
            openRoom()
            compose.waitUntil(15000) { model!!.state.value.snapshot?.chat?.pending?.any { it.text == queued } == true }
            command("resume")
            peerReceives(queued); waitMessage(queued)
            evidence.put("offlineQueueOwnerReopen", true).put("offlinePeerCount", 1)
            android.util.Log.i("SharedSDKAcceptance", "offline queue reopened and delivered once")
            compose.onNodeWithTag("shared_composer").performTextInput("不得进入其他账号的草稿")
            // A -> B: UI returns to root, private A-C room and A composer never enter B's snapshot.
            compose.onNodeWithTag("shared_chat_back").performClick()
            compose.onNodeWithText("我的").performClick()
            compose.onNodeWithTag("shared_switch_account").performClick()
            compose.waitUntil(20000) { !model!!.state.value.busy && !model!!.state.value.exitPending && model!!.state.value.snapshot?.userID == null }
            login(1)
            compose.waitUntil(45000) { model!!.state.value.snapshot?.conversations?.any { it.id == sharedRoom } == true }
            assertFalse(model!!.state.value.snapshot!!.conversations.any { it.id == privateRoom })
            assertNull(model!!.state.value.snapshot!!.chat)
            compose.onNodeWithTag("shared_room_${privateRoom}").assertDoesNotExist()
            openRoom(); waitMessage(outgoing); waitMessage(queued)
            compose.onNodeWithText("不得进入其他账号的草稿").assertDoesNotExist()
            val reply = "切换后由 B 回复 $run"
            compose.onNodeWithTag("shared_composer").performTextInput(reply)
            compose.onNodeWithTag("shared_send").assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick) { it() }; waitMessage(reply)
            compose.onNodeWithTag("shared_chat_back").performClick()
            compose.onNodeWithText("我的").performClick()
            compose.onNodeWithTag("shared_sign_out").performClick()
            compose.waitUntil(20000) { !model!!.state.value.busy && !model!!.state.value.exitPending }
            scenario!!.close(); scenario = null
            withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            reopened = SharedClient.open(context, SharedEndpoint(base, "localhost", port))
            val signedOut = reopened!!.restore()
            assertNull(signedOut.userID); assertTrue(signedOut.conversations.isEmpty()); assertNull(signedOut.chat)
            reopened!!.close(); reopened = null
            launchApp(); assertNull(model!!.state.value.snapshot?.userID); login(0)
            compose.waitUntil(45000) { model!!.state.value.snapshot?.conversations?.any { it.id == privateRoom } == true }
            openRoom(); waitMessage(reply)
            evidence.put("switchAToBIsolated", true).put("signedOutReopen", true).put("switchBackToA", true)
            scenario!!.close(); scenario = null
            withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            peerJob!!.cancelAndJoin(); peerJob = null
            peer!!.signOut()
            val stale = runCatching { retainedWindow!!.snapshot() }.exceptionOrNull()
            assertTrue(stale is SharedSdkException && stale.reason in setOf(SharedError.Closed, SharedError.AuthenticationRequired))
            retainedWindow!!.close(); retainedWindow = null
            evidence.put("oldWindowRejectedAfterSignOut", true)
            peer!!.close(); peer = null
            assertEquals(0, SharedClient.activeClientCount())
            assertEquals(0, SharedClient.activeOperationCount())
            assertEquals(0, AndroidRuntimePlatform.install(context).activeConnectionCount)
            assertEquals(0, AndroidRuntimePlatform.install(context).activeHttpCount)
            java.net.ServerSocket(0).use { listener ->
                val accepted = java.util.concurrent.CountDownLatch(1)
                val disconnected = java.util.concurrent.CountDownLatch(1)
                val socketPeer = kotlin.concurrent.thread {
                    listener.accept().use { socket ->
                        socket.soTimeout = 10000; accepted.countDown()
                        try { while (socket.inputStream.read() >= 0) { } } finally { disconnected.countDown() }
                    }
                }
                val cancelled = SharedClient.open(context, SharedEndpoint("https://localhost:${listener.localPort}", "localhost", port))
                try {
                    val login = launch(Dispatchers.Default) { cancelled.login("cancelled-account", "cancelled-password") }
                    withTimeout(10000) { while (accepted.count != 0L) delay(10) }
                    val elapsed = kotlin.system.measureTimeMillis { login.cancelAndJoin() }
                    assertTrue(elapsed < 2000)
                    assertTrue(disconnected.await(2, java.util.concurrent.TimeUnit.SECONDS))
                    evidence.put("loginCancellationMilliseconds", elapsed)
                } finally { cancelled.close(); socketPeer.join(2000) }
            }
            assertEquals(0, SharedClient.activeClientCount()); assertEquals(0, SharedClient.activeOperationCount())
            assertEquals(0, AndroidRuntimePlatform.install(context).activeHttpCount)
            evidence.put("crossAccountReadDenied", true).put("draftIsolated", true).put("wrongPasswordRejected", true)
            File(context.filesDir, "shared-sdk-evidence.json").writeText(evidence.put("passed", true).put("leakedClients", 0).put("leakedOperations", 0).toString(2))
        } finally {
            scenario?.close(); reopened?.close(); peerJob?.cancelAndJoin(); peer?.close()
        }
    }
}
