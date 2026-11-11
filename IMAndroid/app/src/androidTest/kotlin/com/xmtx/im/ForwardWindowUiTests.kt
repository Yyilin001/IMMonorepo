package com.xmtx.im

import android.app.Application
import android.graphics.Bitmap
import android.database.sqlite.SQLiteDatabase
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ForwardWindowUiTests {
    @get:Rule val compose=createComposeRule()
    @Test fun selectionSurvivesPaginationChangesRestorationAndClosedPageWithoutGlobalBodies() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val actor=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString())
        val room=RoomId(UUID.randomUUID().toString());val target=RoomId(UUID.randomUUID().toString())
        fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
        val store=openBoundFixtureStore(context,actor,device)
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        fun database(body: (SQLiteDatabase)->Unit)=SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
        runBlocking {store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(240).setViewerMembershipRevision(1).build())}
        database {db->db.beginTransaction();try {
            for(n in 1..240) db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)",
                arrayOf<Any>(id(n).value,room.value,actor.value,"可选来源 $n",n,n*10,n))
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
        val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("forward",model)}
        var page: ConversationTimelineSession?=null
        var active by mutableStateOf(true)
        var app by mutableStateOf(AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(target,"目标",kind=RoomKind.Group)))))
        var submitted: PersistentList<SelectedForwardMessage>?=null
        val restore=StateRestorationTester(compose)
        fun awaitPage() {compose.waitUntil(10000) {page?.state?.value?.let {it.loaded && !it.loading}==true};compose.waitForIdle()}
        fun clickText(text: String) {compose.onNodeWithTag("forward-list").performScrollToNode(hasText(text));compose.onNodeWithText(text).performClick()}
        try {
            restore.setContent {val scope=rememberCoroutineScope();MaterialTheme {
                ForwardPage(room,id(180),app,model,active,openTimeline={ConversationTimelineSession(store,it,actor,scope).also {opened->page=opened}},
                    submit={_,sources,targets->assertEquals(persistentListOf(target),targets);submitted=sources;false},back={error("Failed submission must keep the selection")})
            }}
            awaitPage()
            compose.onNodeWithTag("forward-list").performScrollToNode(hasContentDescription("来源 ${id(180).value}"))
            compose.onNodeWithContentDescription("来源 ${id(180).value}").assertIsOn()
            clickText("更早的消息");awaitPage();clickText("更早的消息");awaitPage()
            compose.runOnIdle {assertTrue(page!!.state.value.window.messages.size<=120);assertTrue(page!!.state.value.window.messages.none {it.id==id(180)});assertTrue(app.snapshot.messages.isEmpty())}
            compose.onNodeWithTag("forward-list").performScrollToNode(hasContentDescription("来源 ${id(2).value}"))
            compose.onNodeWithContentDescription("来源 ${id(2).value}").performClick()
            // Current projection no longer contains either selected version.
            database {db->db.execSQL("UPDATE messages SET revision=2,text='后续编辑' WHERE id=?",arrayOf(id(2).value));db.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(180).value))}
            compose.runOnIdle {page!!.refresh()};awaitPage()
            compose.onNodeWithTag("forward-list").performScrollToNode(hasContentDescription("目标 目标"))
            compose.onNodeWithContentDescription("目标 目标").performClick()
            restore.emulateSavedInstanceStateRestore();awaitPage()
            compose.onNodeWithTag("forward-list").performScrollToNode(hasContentDescription("定位已选消息 1"))
            compose.onNodeWithContentDescription("定位已选消息 1").performClick();awaitPage()
            compose.onNodeWithText("这条消息当前不可用。").assertExists()
            clickText("确认转发")
            compose.runOnIdle {assertEquals(setOf(SelectedForwardMessage(id(180),1,180),SelectedForwardMessage(id(2),1,2)),submitted?.toSet())}
            if(InstrumentationRegistry.getArguments().getString("captureForward")=="true") context.openFileOutput("forward-window.png",0).use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
            }
            val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
            compose.runOnIdle {active=true};awaitPage();assertNotSame(old,page)
            clickText("确认转发")
            compose.runOnIdle {assertEquals(2,submitted!!.size);app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
            compose.onNodeWithText("确认转发").performScrollTo().assertIsNotEnabled()
        } finally {
            compose.runOnIdle {page?.close();owners.clear()};runBlocking {page?.awaitClosed()};store.close()
        }
    }
}
