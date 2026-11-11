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
import kotlinx.coroutines.CompletableDeferred
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MessageSearchUiTests {
    @get:Rule val compose=createComposeRule()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val other=UserId(UUID.randomUUID().toString())
    private val device=DeviceId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private lateinit var store: SqliteClientStore
    private var timelineStore: ConversationTimelineStore?=null
    private var page: MessageSearchSession?=null;private var timeline: ConversationTimelineSession?=null
    private var active by mutableStateOf(true);private var selected by mutableStateOf<MessageSearchHit?>(null)
    private val app=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"搜索验证"))))
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    @Before fun setup()=runBlocking<Unit> {
        store=openBoundFixtureStore(context,actor,device);store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(120).setViewerMembershipRevision(1).build())
        database {db->db.beginTransaction();try {(1..120).forEach {n ->
            db.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,?,1,?,?,0)",
                arrayOf<Any>(id(n).value,room.value,if(n%2==0) actor.value else other.value,"needle 消息 $n","needle 消息 $n",n,n,n))
        };db.setTransactionSuccessful()} finally {db.endTransaction()}}
        repeat(5) {store.processMessageSearchIndex(32)}
    }
    @After fun cleanup() {
        compose.runOnIdle {page?.close();timeline?.close()};runBlocking {page?.awaitClosed();timeline?.awaitClosed()};store.close()
    }
    @Composable private fun Content() {
        val scope=rememberCoroutineScope()
        MaterialTheme {
            val hit=selected
            if(hit==null) MessageSearchScreen(app,SessionUi.SignedIn(actor),active,
                open={MessageSearchSession(store,actor,scope).also {page=it}},selected={selected=it})
            else Chat(app,SessionUi.SignedIn(actor),room,{_,_->true},active=active,openTimeline={ConversationTimelineSession(timelineStore ?: store,room,actor,scope).also {timeline=it}},focusMessage=hit.message)
        }
    }
    private fun awaitHits(size: Int) {compose.waitUntil(10000) {page?.state?.value?.let {!it.loading && it.page.hits.size==size}==true};compose.waitForIdle()}
    private fun query(text: String) {compose.onNodeWithTag("message-search-query").performTextReplacement(text);awaitHits(if(text=="needle") 50 else 0)}
    @Test fun databaseSearchPaginatesWithoutGlobalBodiesAndOpensTheExactMessage() {
        compose.setContent {Content()};query("needle")
        compose.onNodeWithTag("message-search-hit-${id(120).value}").assertIsDisplayed()
        compose.onNodeWithTag("message-search-next").performClick();awaitHits(50)
        compose.waitUntil(5000) {page?.state?.value?.page?.hits?.firstOrNull()?.message==id(70)}
        compose.onNodeWithTag("message-search-hit-${id(70).value}").assertIsDisplayed()
        compose.runOnIdle {assertTrue(app.snapshot.messages.isEmpty());assertEquals(50,page!!.state.value.page.hits.size)}
        if(InstrumentationRegistry.getArguments().getString("captureSearch")=="true") context.openFileOutput("message-search-page.png",0).use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
        }
        compose.onNodeWithTag("message-search-hit-${id(70).value}").performClick()
        compose.waitUntil(10000) {timeline?.state?.value?.loaded==true}
        try {
            compose.waitUntil(5000) {runCatching {compose.onNodeWithTag("chat-row-${id(70).value}",useUnmergedTree=true).assertIsDisplayed()}.isSuccess}
        } catch(failure: Throwable) {
            println("Search target=${selected?.message} navigation=${timeline?.state?.value?.navigation} window=${timeline?.state?.value?.window?.messages?.firstOrNull()?.id}..${timeline?.state?.value?.window?.messages?.lastOrNull()?.id}")
            context.openFileOutput("message-search-target-failure.png",0).use {compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)}
            throw failure
        }
        compose.onNodeWithTag("chat-row-${id(70).value}",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
    }
    @Test fun senderContentFiltersAndSavedQuerySurviveRecreationAndInactiveOwnerIsClosed() {
        val restoration=StateRestorationTester(compose);restoration.setContent {Content()};query("needle")
        compose.onNodeWithText("仅自己").performClick();awaitHits(50)
        compose.waitUntil(5000) {page?.state?.value?.request?.sender==actor}
        compose.runOnIdle {assertTrue(page!!.state.value.page.hits.all {it.sender==actor})}
        restoration.emulateSavedInstanceStateRestore();awaitHits(50)
        compose.onNodeWithTag("message-search-query").assertTextContains("needle");compose.onNodeWithText("仅自己").assertIsSelected()
        val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
        compose.runOnIdle {active=true};awaitHits(50);assertNotSame(old,page)
        compose.onNodeWithTag("message-search-content").performClick();compose.onNodeWithText("图片").performClick();awaitHits(0)
        compose.onNodeWithText("没有找到消息").assertIsDisplayed()
    }
    @Test fun indexUpdatesRemoveEditedHitsAndBlankQueryClearsOldResults() {
        compose.setContent {Content()};query("needle")
        database {it.execSQL("UPDATE messages SET text='changed',source_text='changed',revision=2 WHERE id=?",arrayOf(id(120).value))}
        val progress=runBlocking {store.processMessageSearchIndex(32)}
        compose.runOnIdle {page!!.indexChanged(progress)}
        compose.waitUntil(10000) {page?.state?.value?.page?.hits?.firstOrNull()?.message==id(119)}
        compose.onNodeWithTag("message-search-hit-${id(120).value}").assertDoesNotExist()
        query("");compose.onNodeWithText("输入关键词，或选择内容类型、发送者").assertIsDisplayed()
    }
    @Test fun initialFocusIntentSurvivesLeavingBeforeItsDatabaseReadCompletes() {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var first=true
        timelineStore=object: ConversationTimelineStore by store {
            override suspend fun locateTimelineMessage(room: RoomId,viewer: UserId,message: MessageId,before: Int,after: Int): TimelineLocation {
                if(first) {first=false;entered.complete(Unit);release.await()}
                return store.locateTimelineMessage(room,viewer,message,before,after)
            }
        }
        compose.setContent {Content()}
        compose.onNodeWithTag("message-search-query").performTextInput("消息 70");awaitHits(1)
        compose.onNodeWithTag("message-search-hit-${id(70).value}").performClick()
        compose.waitUntil(5000) {entered.isCompleted}
        val old=timeline
        compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
        release.complete(Unit);compose.runOnIdle {active=true}
        compose.waitUntil(10000) {runCatching {compose.onNodeWithTag("chat-row-${id(70).value}",useUnmergedTree=true).assertIsDisplayed()}.isSuccess}
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed();assertNotSame(old,timeline)
    }
}
