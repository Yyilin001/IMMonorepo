package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

class SendHistoryUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun command(n: Int)=MessageCommand.text(actor,room,"本地发送 $n",600000+n.toLong(),id(n+1000).value)
    private lateinit var model: AppViewModel;private lateinit var models: ViewModelStore;private lateinit var store: SqliteClientStore
    private var app by mutableStateOf(AppState())
    private var page: SendHistorySession?=null
    private var active by mutableStateOf(true)
    @Before fun setup() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        model=AppViewModel(context.applicationContext as Application);models=ViewModelStore().apply {put("send-history",model)}
        app=installMediaNavigationSource(model,AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"发送记录来源",kind=RoomKind.Group)),
            messages=persistentListOf(Message(id(125),room,actor,"已同步正文",125)))))
        store=AppViewModel::class.java.getDeclaredField("local").apply {isAccessible=true}.get(model) as SqliteClientStore
        runBlocking {for(n in 1..125) store.enqueue(command(n))}
    }
    private var showing by mutableStateOf(true)
    private fun content(body: @Composable ()->Unit) {compose.setContent {if(showing) body()}}
    @After fun cleanup() {compose.runOnIdle {showing=false};compose.waitForIdle();compose.runOnUiThread {models.clear()};awaitMediaNavigationClosed(model)}
    private fun awaitPage(first: Int) {compose.waitUntil(10000) {page?.state?.value?.let {!it.loading && it.page.items.firstOrNull()?.operation==command(first).clientMessageId}==true};compose.waitForIdle()}
    private fun accept()=runBlocking {
        val command=command(125)
        store.complete(command.clientMessageId,MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(command.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint))
            .setResolvedAtMs(100000).setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(id(125).value).setRoomSequence(1)).build())
    }
    @Test fun finitePagesRefreshAndClearOnInactiveRevokedAndBackgroundStates() {
        content {MaterialTheme {SendHistoryScreen(app,room,active,{model.openSendHistory(it).also {page=it}},{},{})}}
        awaitPage(125);assertTrue(app.snapshot.messages.isEmpty());assertEquals(50,page!!.state.value.page.items.size)
        compose.onNodeWithText("下一页").performClick();awaitPage(75);compose.onNodeWithText("本地发送 125").assertDoesNotExist()
        compose.onNodeWithText("下一页").performClick();awaitPage(25);assertEquals(25,page!!.state.value.page.items.size)
        compose.onNodeWithText("上一页").performClick();awaitPage(75)
        compose.onNodeWithText("刷新记录").performClick();awaitPage(125)
        accept();compose.runOnIdle {AppViewModel::class.java.getDeclaredMethod("publishSnapshot",ClientSnapshot::class.java).apply {isAccessible=true}.invoke(model,app.snapshot)}
        compose.waitUntil(10000) {page?.state?.value?.page?.items?.firstOrNull()?.message==id(125)}
        compose.onNodeWithText("已同步正文").assertIsDisplayed();compose.onNodeWithText("本地发送 125").assertDoesNotExist()
        val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
        compose.onNodeWithText("已同步正文").assertDoesNotExist();compose.runOnIdle {active=true};awaitPage(125);assertNotSame(old,page)
        val revoked=page;compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.waitForIdle();assertTrue(revoked!!.state.value.closed);compose.onNodeWithText("已同步正文").assertDoesNotExist()
        compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf()))};awaitPage(125)
        compose.runOnIdle {model.foreground(false)};compose.waitForIdle();assertTrue(page!!.state.value.closed)
        compose.onNodeWithText("已同步正文").assertDoesNotExist()
    }
    @Test fun roomSettingsEntryRestoresSharedStackAndLocatesCurrentMessage() {
        accept();val restore=StateRestorationTester(compose)
        restore.setContent {if(showing) {val stack=rememberNavBackStack(Route.Home,Route.Settings(room.value));MaterialTheme {SignedIn(app,SessionUi.SignedIn(actor),model,stack)}}}
        compose.onNodeWithText("发送记录").performScrollTo().performClick()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("send-history-${command(125).clientMessageId}").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("打开消息").performClick()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("chat-focused-message").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("已定位到原消息").assertIsDisplayed()
        restore.emulateSavedInstanceStateRestore()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("chat-focused-message").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("返回").performClick()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("send-history-${command(125).clientMessageId}").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("会话整理").assertExists()
        compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("我的").assertExists()
    }
    @Test fun provenUnsentTextRetryCreatesOneNewRecordAndRetiresOldButton() {
        val original=command(125)
        runBlocking {store.complete(original.clientMessageId,MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(original.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(original.fingerprintVersion).setDigest(original.fingerprint))
            .setResolvedAtMs(100000).setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(6)).build())}
        content {val scope=rememberCoroutineScope();MaterialTheme {SendHistoryScreen(app,room,true,{model.openSendHistory(it).also {page=it}},{},{},
            replaceText={operation->scope.launch {model.replaceUnsentText(room,operation)}})}}
        awaitPage(125);compose.onNodeWithText("重新发送").assertIsDisplayed().performClick()
        compose.waitUntil(10000) {page?.state?.value?.page?.items?.any {it.operation==original.clientMessageId && it.replacement!=null}==true}
        compose.onNodeWithText("重新发送").assertDoesNotExist()
        compose.onNodeWithText("已创建新的发送记录").assertIsDisplayed()
        runBlocking {
            val record=store.sendHistory(room,actor).items.first {it.operation==original.clientMessageId}
            assertEquals(record.replacement,store.replaceUnsentText(room,actor,original.clientMessageId,System.currentTimeMillis()))
            assertEquals(1,store.pending().count {it.clientMessageId==record.replacement && it.text==original.text})
        }
    }
    @Test fun provenUnsentTextCanBeAbandonedAndCannotBeResentFromTheRecord() {
        val original=command(125)
        runBlocking {store.complete(original.clientMessageId,MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(original.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(original.fingerprintVersion).setDigest(original.fingerprint))
            .setResolvedAtMs(100000).setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(6)).build())}
        content {val scope=rememberCoroutineScope();MaterialTheme {SendHistoryScreen(app,room,active,{model.openSendHistory(it).also {page=it}},{},{},
            abandonText={operation->scope.launch {model.abandonUnsentText(room,operation)}})}}
        awaitPage(125);compose.onNodeWithText("放弃发送").assertIsDisplayed().performClick()
        compose.waitUntil(10000) {page?.state?.value?.page?.items?.firstOrNull()?.abandoned==true}
        compose.onNodeWithText("已放弃发送").assertIsDisplayed()
        compose.onNodeWithText("放弃发送").assertDoesNotExist();compose.onNodeWithText("重新发送").assertDoesNotExist()
        compose.runOnIdle {active=false};compose.waitForIdle();compose.runOnIdle {active=true};awaitPage(125)
        compose.onNodeWithText("已放弃发送").assertIsDisplayed();compose.onNodeWithText("重新发送").assertDoesNotExist()
        runBlocking {
            val first=store.sendHistory(room,actor,limit=100)
            val second=store.sendHistory(room,actor,SendHistorySelection.Before(first.next!!),100)
            assertEquals(125,first.items.size+second.items.size)
        }
    }
    @Test fun manualConfirmationUsesOriginalIdentityAndPreservesServerCooldown() {
        val frozen=runBlocking {store.claimSend(1000)!!}
        val floor=System.currentTimeMillis()+120000
        runBlocking {store.deferSend(frozen,frozen.state.copy(status=SendRecoveryStatus.NeedsAttention,nextAt=floor))}
        content {val scope=rememberCoroutineScope();MaterialTheme {SendHistoryScreen(app,room,true,{model.openSendHistory(it).also {page=it}},{},{},
            {operation->scope.launch {model.resumeSendConfirmation(room,operation)}})}}
        awaitPage(125);compose.onNodeWithText("下一页").performClick();awaitPage(75);compose.onNodeWithText("下一页").performClick();awaitPage(25)
        compose.onNodeWithTag("send-history-list").performScrollToNode(hasTestTag("send-history-${command(1).clientMessageId}"))
        compose.onNodeWithText("原消息结果未知，确认已暂停").assertIsDisplayed()
        compose.onNodeWithText("放弃发送").assertDoesNotExist();compose.onNodeWithText("重新发送").assertDoesNotExist()
        compose.onNodeWithText("继续确认").performClick()
        compose.waitUntil(10000) {page?.state?.value?.page?.items?.lastOrNull()?.status==SendRecordStatus.Confirming}
        compose.onNodeWithText("继续确认").assertDoesNotExist()
        runBlocking {assertEquals(frozen.command,store.pending().first());assertNull(store.claimSend(floor-1))}
    }


    @Test fun connectionWaitsExposeReasonsWithoutUnsafeRetryOrAbandonActions() {
        val frozen=runBlocking {store.claimSend(1000)!!}
        runBlocking {store.deferSend(frozen,frozen.state.copy(action=SendAction.Submit,status=SendRecoveryStatus.WaitingForNetwork))}
        content {MaterialTheme {SendHistoryScreen(app,room,true,{model.openSendHistory(it).also {page=it}},{},{})}}
        awaitPage(125);compose.onNodeWithText("下一页").performClick();awaitPage(75);compose.onNodeWithText("下一页").performClick();awaitPage(25)
        compose.onNodeWithTag("send-history-list").performScrollToNode(hasTestTag("send-history-${command(1).clientMessageId}"))
        compose.onNodeWithText("等待网络连接后继续").assertIsDisplayed()
        compose.onNodeWithText("继续确认").assertDoesNotExist();compose.onNodeWithText("放弃发送").assertDoesNotExist();compose.onNodeWithText("重新发送").assertDoesNotExist()
        runBlocking {
            store.resumeNetworkWaitingSends(actor,2000)
            val next=store.claimSend(2000)!!;assertEquals(frozen.command,next.command)
            store.deferSend(next,next.state.copy(action=SendAction.Submit,status=SendRecoveryStatus.WaitingForAuthentication))
        }
        compose.runOnIdle {AppViewModel::class.java.getDeclaredMethod("publishSnapshot",ClientSnapshot::class.java).apply {isAccessible=true}.invoke(model,app.snapshot)}
        compose.waitUntil(10000) {page?.state?.value?.page?.items?.lastOrNull()?.status==SendRecordStatus.WaitingForAuthentication}
        compose.onNodeWithText("等待登录恢复后继续").assertIsDisplayed();compose.onNodeWithText("等待网络连接后继续").assertDoesNotExist()
        compose.onNodeWithText("继续确认").assertDoesNotExist();compose.onNodeWithText("放弃发送").assertDoesNotExist();compose.onNodeWithText("重新发送").assertDoesNotExist()
    }
}
