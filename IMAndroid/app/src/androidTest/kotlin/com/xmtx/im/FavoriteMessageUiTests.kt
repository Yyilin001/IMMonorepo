package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

class FavoriteMessageUiTests {
    @get:Rule val compose=createComposeRule()
    private val actor=UserId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private lateinit var model: AppViewModel;private lateinit var models: ViewModelStore;private lateinit var store: SqliteClientStore
    private lateinit var app: AppState
    private var page: FavoriteMessageSession?=null
    private var active by mutableStateOf(true)
    @Before fun setup() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        model=AppViewModel(context.applicationContext as Application);models=ViewModelStore().apply {put("favorites",model)}
        app=installMediaNavigationSource(model,AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"收藏来源",kind=RoomKind.Group)),
            messages=(1..125).map {Message(id(it),room,actor,"收藏正文 $it",it.toLong())}.toPersistentList())))
        store=AppViewModel::class.java.getDeclaredField("local").apply {isAccessible=true}.get(model) as SqliteClientStore
        runBlocking {project((1..125).toList())}
    }
    @After fun cleanup() {compose.runOnUiThread {models.clear()};awaitMediaNavigationClosed(model)}
    private suspend fun project(ids: List<Int>,favorite: Boolean=true,revision: Long=1) {
        val cursor=store.cursor();val batch=SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("token-${cursor.sequence+ids.size}").setSyncReceipt("receipt-${cursor.sequence+ids.size}")
        ids.forEachIndexed {i,n->val value=buildJsonObject {put("room_id",room.value);put("message_id",id(n).value);put("revision",revision);put("updated_at_ms",n);put("is_favorited",favorite)}
            batch.addRecords(SyncRecord.newBuilder().setUserSyncSequence(cursor.sequence+i+1).setSourceEventId("favorite-${cursor.sequence+i+1}").setProjectionKind("message_favorite").setPayload(ByteString.copyFromUtf8(value.toString())))}
        store.commit(batch.build(),cursor)
    }
    private fun awaitPage(first: Int) {compose.waitUntil(10000) {page?.state?.value?.let {!it.loading && it.page.items.firstOrNull()?.message==id(first)}==true};compose.waitForIdle()}
    @Test fun databasePagesStayFiniteRefreshOnPublicationAndCloseWithTheAccount() {
        compose.setContent {MaterialTheme {FavoritesPage(app,model,{},active,open={model.openFavorites().also {page=it}})}}
        awaitPage(125);assertTrue(app.snapshot.messages.isEmpty());assertEquals(50,page!!.state.value.page.items.size)
        compose.onNodeWithText("下一页").performClick();awaitPage(75)
        compose.onNodeWithText("收藏正文 125").assertDoesNotExist();compose.onNodeWithText("上一页").performClick();awaitPage(125)
        runBlocking {project(listOf(125),false,2)}
        compose.runOnIdle {AppViewModel::class.java.getDeclaredMethod("publishSnapshot",ClientSnapshot::class.java).apply {isAccessible=true}.invoke(model,app.snapshot)}
        awaitPage(124);compose.onNodeWithText("收藏正文 125").assertDoesNotExist()
        val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed);compose.onNodeWithText("收藏正文 124").assertDoesNotExist()
        compose.runOnIdle {active=true};awaitPage(124);assertNotSame(old,page)
        compose.runOnUiThread {models.clear()};awaitMediaNavigationClosed(model)
        compose.onNodeWithText("收藏正文 124").assertDoesNotExist();assertTrue(page!!.state.value.closed)
    }
    @Test fun favoriteRoutesLocateOriginalMessageAndRestoreTheSharedStack() {
        val restore=StateRestorationTester(compose)
        restore.setContent {val stack=rememberNavBackStack(Route.Home,Route.Page(PageKind.Favorites));MaterialTheme {SignedIn(app,SessionUi.SignedIn(actor),model,stack)}}
        compose.waitUntil(10000) {compose.onAllNodesWithTag("favorite-${id(125).value}").fetchSemanticsNodes().isNotEmpty()}
        if(InstrumentationRegistry.getArguments().getString("captureFavorites")=="true") {
            val context=InstrumentationRegistry.getInstrumentation().targetContext
            context.openFileOutput("favorite-message-page.png",0).use {compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
        }
        compose.onNode(hasText("打开聊天") and hasAnyAncestor(hasTestTag("favorite-${id(125).value}"))).performClick()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("chat-focused-message").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("已定位到原消息").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
        restore.emulateSavedInstanceStateRestore()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("chat-focused-message").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("已定位到原消息").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.waitUntil(10000) {compose.onAllNodesWithTag("favorite-${id(125).value}").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("我的").assertExists()
    }
}
