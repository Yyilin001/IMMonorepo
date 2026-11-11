package com.xmtx.im

import android.database.sqlite.SQLiteDatabase
import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ChatTimelineWindowTests {
    private fun activity(n:Int,sequence:Long=n.toLong())=runBlocking {
        val cursor=store.cursor()
        store.commit(com.xmtx.imclientkit.generated.im.realtime.v2.SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("token").setSyncReceipt("receipt")
            .addRecords(com.xmtx.imclientkit.generated.im.realtime.v2.SyncRecord.newBuilder().setUserSyncSequence(cursor.sequence+1).setSourceEventId(id(n).value).setProjectionKind("timeline_activity")
                .setPayload(com.google.protobuf.ByteString.copyFromUtf8("""{"room_id":"${room.value}","event_type":"direct_message_restricted","timeline_sequence":$sequence,"server_created_at_ms":1}"""))).build(),cursor)
    }
    @Test fun privateActivitiesRenderWithoutMessageActionsAndNeverAdvanceReadCheckpointAlone() {
        database {it.execSQL("DELETE FROM messages")};(1..6).forEach {activity(it)}
        compose.setContent {Content()};awaitWindow()
        compose.onNodeWithTag("chat-activity-${id(6).value}").assertIsDisplayed().assertHasNoClickAction()
        compose.onAllNodesWithText("当前无法向此会话发送消息").assertCountEquals(6)
        compose.onNodeWithText("消息操作").assertDoesNotExist()
        compose.runOnIdle {assertTrue(reported.isEmpty());assertTrue(page!!.state.value.window.messages.isEmpty())}
    }
    @Test fun activityAndMessageWithTheSameIdentityRenderSeparatelyAndActivitySequenceIsNotReadEvidence() {
        activity(300,10000)
        compose.setContent {Content()};awaitWindow()
        compose.onNodeWithTag("chat-activity-${id(300).value}").assertIsDisplayed().assertHasNoClickAction()
        row(300).assertIsDisplayed()
        compose.runOnIdle {assertEquals(120,page!!.state.value.window.entries.size);assertTrue(reported.all {it<=300})}
        if(InstrumentationRegistry.getArguments().getString("captureTimelineActivity")=="true") context.openFileOutput("timeline-activity.png",0).use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
        }
    }
    @Test fun activityHistoryAnchorSurvivesSavedStateAndUsesActivityLookup() {
        database {it.execSQL("DELETE FROM messages")};(1..160).forEach {activity(it)}
        val restoration=StateRestorationTester(compose);restoration.setContent {Content()};awaitWindow()
        compose.onNodeWithTag("chat-older-messages").performClick();awaitWindow()
        compose.onNodeWithTag("chat-activity-${id(41).value}").assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore();awaitWindow()
        compose.onNodeWithTag("chat-activity-${id(41).value}").assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertDoesNotExist()
        compose.runOnIdle {assertTrue(reported.isEmpty());assertEquals(null,page!!.state.value.navigation?.message)}
    }
    @get:Rule val compose=createComposeRule()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private lateinit var store: SqliteClientStore
    private var page: ConversationTimelineSession?=null
    private var active by mutableStateOf(true)
    private var appState by mutableStateOf(AppState(session=SessionUi.SignedIn(actor),snapshot=ClientSnapshot(
        conversations=persistentListOf(Conversation(room,"时间线窗口")),
        // Deliberately no global message bodies. The chat must obtain them through the local window API.
        readCheckpoints=persistentListOf(RoomReadCheckpoint(room,99999,99999)))))
    private val reported=mutableListOf<Long>()
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private fun insert(db: SQLiteDatabase,n: Int) {
        db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,?,?,0,?)",
            arrayOf<Any>(id(n).value,room.value,actor.value,"窗口消息 $n\n正文内容",n.toLong(),n.toLong(),n.toLong(),(if(n==300) MessageRichContent(replyTo=id(1)) else MessageRichContent.Empty).payload().toString()))
    }
    @Before fun prepare()=runBlocking<Unit> {
        store=openBoundFixtureStore(context,actor,device)
        store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(300).setViewerMembershipRevision(1).build())
        database {db -> db.beginTransaction();try {
            (1..300).forEach {insert(db,it)};db.execSQL("UPDATE room_cursors SET sequence=300 WHERE room=?",arrayOf(room.value));db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
    }
    @After fun cleanup() {
        val closing=page
        compose.runOnIdle {closing?.close()}
        runBlocking {closing?.awaitClosed()};store.close()
    }
    @Composable private fun Content() {
        val scope=rememberCoroutineScope()
        MaterialTheme {Chat(appState,SessionUi.SignedIn(actor),room,{_,_->true},active=active,
            reportRead={_,sequence->reported+=sequence},openTimeline={ConversationTimelineSession(store,room,actor,scope).also {page=it}})}
    }
    private fun row(n: Int)=compose.onNodeWithTag("chat-row-${id(n).value}",useUnmergedTree=true)
    private fun awaitWindow() {compose.waitUntil(10000) {page?.state?.value?.let {it.loaded && !it.loading && !it.closed} == true};compose.waitForIdle()}
    private fun focus() {
        compose.onNodeWithTag("reply-reference-${id(300).value}").performClick();awaitWindow()
        row(1).assertIsDisplayed();compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
    }
    @Test fun replyOutsideWindowLoadsDirectlyAndHistoricalTailNeverMarksLatestHeadRead() {
        compose.setContent {Content()};awaitWindow();row(300).assertIsDisplayed()
        compose.runOnIdle {assertEquals(120,page!!.state.value.window.messages.size);assertTrue(appState.snapshot.messages.isEmpty());reported.clear()}
        focus()
        // While the ID lookup is running, the prior latest page is still legitimately visible.
        // Measure only after the historical window is rendered, then reach its actual bottom.
        compose.runOnIdle {reported.clear()}
        compose.onNodeWithTag("chat-timeline").performScrollToIndex(page!!.state.value.window.messages.lastIndex)
        row(61).assertIsDisplayed()
        compose.runOnIdle {
            assertTrue("Expected a historical viewport read report",reported.isNotEmpty())
            assertTrue("Historical window advanced to $reported",reported.all {it <= 61})
            assertEquals(id(62),page!!.state.value.window.newerBoundary?.message)
            page!!.locate(id(1))
        }
        awaitWindow();row(1).assertIsDisplayed()
        val top=row(1).fetchSemanticsNode().boundsInRoot.top
        database {db -> insert(db,301);db.execSQL("UPDATE room_cursors SET sequence=301 WHERE room=?",arrayOf(room.value))}
        compose.runOnIdle {page!!.refresh()};awaitWindow()
        row(1).assertIsDisplayed();assertEquals(top,row(1).fetchSemanticsNode().boundsInRoot.top,1f)
        if(InstrumentationRegistry.getArguments().getString("captureTimeline")=="true") context.openFileOutput("timeline-window-focus.png",0).use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
        }
        compose.onNodeWithTag("chat-return-latest").performClick();awaitWindow();row(301).assertIsDisplayed()
        compose.runOnIdle {assertEquals(120,page!!.state.value.window.messages.size)}
    }
    @Test fun olderAndNewerWindowsReplaceRowsWithOverlapAndExplicitReturn() {
        compose.setContent {Content()};awaitWindow()
        compose.onNodeWithTag("chat-older-messages").performClick();awaitWindow();row(181).assertIsDisplayed()
        compose.runOnIdle {assertEquals((121..240).map(::id),page!!.state.value.window.messages.map {it.id})}
        compose.onNodeWithTag("chat-newer-messages").performClick();awaitWindow();row(240).assertIsDisplayed()
        compose.runOnIdle {assertEquals((181..300).map(::id),page!!.state.value.window.messages.map {it.id})}
        compose.onNodeWithTag("chat-newer-messages").assertDoesNotExist()
        compose.onNodeWithTag("chat-return-latest").performClick();awaitWindow();row(300).assertIsDisplayed()
    }
    @Test fun restorationAndInactivePageReopenLocateTheSavedMessageInsteadOfLoadingLatest() {
        val restoration=StateRestorationTester(compose)
        restoration.setContent {Content()};awaitWindow();focus()
        restoration.emulateSavedInstanceStateRestore();awaitWindow();row(1).assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
        val old=page
        compose.runOnIdle {active=false};compose.waitForIdle()
        assertTrue(old!!.state.value.closed);assertTrue(old.state.value.window.messages.isEmpty())
        database {insert(it,301)}
        compose.runOnIdle {active=true};awaitWindow();row(1).assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed();assertNotSame(old,page)
    }
    @Test fun withdrawalBetweenPreviewAndClickShowsFeedbackAndRevocationClosesOwner() {
        compose.setContent {Content()};awaitWindow()
        database {it.execSQL("UPDATE messages SET withdrawn=1,text='已撤回' WHERE id=?",arrayOf(id(1).value))}
        compose.onNodeWithTag("reply-reference-${id(300).value}").performClick();awaitWindow()
        compose.onNodeWithText("这条消息已撤回。").assertIsDisplayed()
        compose.onNodeWithTag("reply-reference-${id(300).value}").assertDoesNotExist()
        compose.onNodeWithTag("chat-focused-message").assertDoesNotExist()
        val old=page
        runBlocking {store.unavailable(room)}
        compose.runOnIdle {appState=appState.copy(snapshot=appState.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.onNodeWithText("此会话已不可访问，无法发送消息").assertIsDisplayed()
        row(300).assertDoesNotExist();assertTrue(old!!.state.value.closed)
    }
    @Test fun outboxEchoesRenderWithoutGlobalBodiesAndDisappearFromHistoricalWindows() {
        val operation=MessageCommand.text(actor,room,"独立待发送回显",System.currentTimeMillis()+595000)
        runBlocking {store.enqueue(operation)}
        compose.setContent {Content()};awaitWindow()
        compose.onNodeWithText("独立待发送回显").assertIsDisplayed()
        compose.runOnIdle {assertTrue(appState.snapshot.messages.isEmpty());assertEquals(1,page!!.state.value.window.outbox.size);page!!.locate(id(1))}
        awaitWindow();compose.onNodeWithText("独立待发送回显").assertDoesNotExist();assertTrue(page!!.state.value.window.outbox.isEmpty())
        compose.onNodeWithTag("chat-return-latest").performClick();awaitWindow();compose.onNodeWithText("独立待发送回显").assertIsDisplayed()
        database {db->db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,1,1,301,301,0)",
            arrayOf(operation.clientMessageId,room.value,actor.value,"正式同步正文"))}
        compose.runOnIdle {page!!.refresh()};awaitWindow()
        compose.onNodeWithText("独立待发送回显").assertDoesNotExist();compose.onNodeWithText("正式同步正文").assertIsDisplayed()
        compose.runOnIdle {assertTrue(page!!.state.value.window.outbox.isEmpty())}
    }

    @Test fun emptyHistoricalWindowNeverShowsPendingEchoUntilExplicitReturnToLatest() {
        runBlocking {store.enqueue(MessageCommand.text(actor,room,"仍在等待发送",System.currentTimeMillis()+595000))}
        compose.setContent {Content()};awaitWindow();compose.onNodeWithText("仍在等待发送").assertIsDisplayed()
        database {it.execSQL("DELETE FROM messages WHERE room=?",arrayOf(room.value))}
        compose.runOnIdle {page!!.older()};awaitWindow()
        compose.onNodeWithText("仍在等待发送").assertDoesNotExist();assertFalse(page!!.state.value.window.latest)
        compose.runOnIdle {page!!.refresh()};awaitWindow();compose.onNodeWithText("仍在等待发送").assertDoesNotExist()
        compose.onNodeWithTag("chat-return-latest").assertIsDisplayed().performClick();awaitWindow()
        compose.onNodeWithText("仍在等待发送").assertIsDisplayed();assertTrue(page!!.state.value.window.latest)
    }

}
