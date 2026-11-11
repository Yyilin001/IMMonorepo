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
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MessageSourcePageUiTests {
    @get:Rule val compose=createComposeRule()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString());private val id=MessageId(UUID.randomUUID().toString())
    private lateinit var store: SqliteClientStore
    private lateinit var model: AppViewModel
    private lateinit var models: ViewModelStore
    private var page: MessageSourceSession?=null
    private var active by mutableStateOf(true)
    private var app by mutableStateOf(AppState(SessionUi.SignedIn(actor)))
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    @Before fun setup()=runBlocking<Unit> {
        store=openBoundFixtureStore(context,actor,device)
        store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(1).setViewerMembershipRevision(1).build())
        database {it.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,1,1,1,0)",
            arrayOf(id.value,room.value,actor.value,"数据库原文","数据库原文"))}
        model=AppViewModel(context.applicationContext as Application);models=ViewModelStore().apply {put("details",model)}
    }
    @After fun cleanup() {compose.runOnIdle {page?.close();models.clear()};runBlocking {page?.awaitClosed()};store.close()}
    @Composable private fun factory(): (RoomId)->MessageSourceSession? {
        val scope=rememberCoroutineScope()
        return {MessageSourceSession(store,it,actor,scope).also {opened->page=opened}}
    }
    private fun awaitSource() {compose.waitUntil(10000) {page?.state?.value?.let {it.loaded && !it.loading}==true};compose.waitForIdle()}
    private fun refresh() {compose.runOnIdle {page!!.refresh()};awaitSource()}
    @Test fun editorLoadsWithoutGlobalBodiesAndPreservesDraftAcrossNewRevisionAndRestoration() {
        val restore=StateRestorationTester(compose);var saved: Pair<Long,String>?=null
        restore.setContent {val open=factory();MaterialTheme {
            MessageEditorPage(room,id,app,model,active,openSources=open,save={_,_,revision,text->saved=revision to text;false},back={error("Not committed")})
        }}
        awaitSource();compose.onNodeWithText("数据库原文").assertIsDisplayed()
        compose.onNodeWithText("消息内容").performTextReplacement("我的编辑草稿")
        database {it.execSQL("UPDATE messages SET revision=2,text='远端新版本',source_text='远端新版本' WHERE id=?",arrayOf(id.value))}
        refresh();compose.onNodeWithText("我的编辑草稿").assertIsDisplayed();compose.onNodeWithText("保存编辑").performScrollTo().assertIsNotEnabled()
        restore.emulateSavedInstanceStateRestore();awaitSource()
        compose.onNodeWithText("我的编辑草稿").assertIsDisplayed()
        if(InstrumentationRegistry.getArguments().getString("captureSourcePages")=="true") context.openFileOutput("message-editor-conflict.png",0).use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG,100,it)
        }
        compose.onNodeWithText("载入最新消息").performScrollTo().performClick()
        compose.onNodeWithText("远端新版本").assertIsDisplayed();compose.onNodeWithText("消息内容").performTextReplacement("基于新版编辑")
        compose.onNodeWithText("保存编辑").performScrollTo().performClick();compose.runOnIdle {assertEquals(2L to "基于新版编辑",saved);assertTrue(app.snapshot.messages.isEmpty())}
        val old=page;compose.runOnIdle {active=false};compose.waitForIdle();assertTrue(old!!.state.value.closed)
        compose.onNodeWithText("保存编辑").assertIsNotEnabled();compose.runOnIdle {active=true};awaitSource();assertNotSame(old,page)
        database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id.value))};refresh()
        compose.onNodeWithText("基于新版编辑").assertExists();compose.onNodeWithText("保存编辑").assertIsNotEnabled()
    }
    @Test fun reactionDetailUsesPersistedBodyAndDropsItWhenWithdrawn() {
        app=app.copy(snapshot=ClientSnapshot(messages=persistentListOf(Message(id,room,actor,"过期全局正文",0,withdrawn=true))))
        compose.setContent {val open=factory();MaterialTheme {MessageReactionsPage(room,id,app,model,active,open)}}
        awaitSource();compose.onNodeWithText("数据库原文").assertIsDisplayed();compose.onNodeWithText("过期全局正文").assertDoesNotExist()
        database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id.value))};refresh()
        compose.onNodeWithText("数据库原文").assertDoesNotExist();compose.onNodeWithText("消息当前不可用，无法修改反应。").assertExists()
    }
    @Test fun readerDetailRefreshesOnSourceRevisionAndClearsWhenOwnershipChanges() {
        var calls=0
        compose.setContent {val open=factory();MaterialTheme {
            ReadReadersScreen(room,id,app,SessionUi.SignedIn(actor),active,openSources=open,fetch={_,_,_->calls++;ReadReadersPage(room,id,persistentListOf(actor),null)})
        }}
        awaitSource();compose.waitUntil(5000) {calls==1};compose.onNodeWithText("已加载 1 位已读成员").assertIsDisplayed()
        database {it.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id.value))};refresh();compose.waitUntil(5000) {calls==2}
        database {it.execSQL("UPDATE messages SET sender=? WHERE id=?",arrayOf(UserId(UUID.randomUUID().toString()).value,id.value))};refresh()
        compose.onNodeWithText("已加载 1 位已读成员").assertDoesNotExist();compose.onNodeWithText("当前无法查看此消息的已读详情").assertExists()
        compose.runOnIdle {assertEquals(2,calls);assertTrue(app.snapshot.messages.isEmpty())}
    }
    @Test fun mutationHistoryLoadsOnlyVisibleSourcesAndHidesDraftBodyAfterRevocation() {
        val missing=MessageId(UUID.randomUUID().toString())
        fun work(message: MessageId,text: String)=MessageMutationWork(MessageMutationCommand(actor,room,message,UUID.randomUUID().toString().uppercase(),1,text,System.currentTimeMillis()+595000))
        app=app.copy(snapshot=ClientSnapshot(mutationOperations=persistentListOf(work(id,"可见操作正文"),work(missing,"无来源操作正文"))))
        compose.setContent {val open=factory();MaterialTheme {MutationHistoryPage(room,app,model,active,open)}}
        compose.waitUntil(10000) {page?.state?.value?.messages?.containsKey(id)==true}
        compose.onNodeWithText("可见操作正文").assertExists();compose.onNodeWithText("无来源操作正文").assertDoesNotExist()
        compose.runOnIdle {assertTrue(page!!.state.value.ids.size<=2);app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.onNodeWithText("可见操作正文").assertDoesNotExist();compose.runOnIdle {assertTrue(page!!.state.value.closed)}
    }
    private val mediaId="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    private fun mediaRead(kind: MessageMediaKind): MessageResourceRead {
        val type=when(kind) {MessageMediaKind.Image->"image/png";MessageMediaKind.Audio->"audio/wav";else->"text/plain"}
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),mediaId),1,"数据库附件",type,100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,
            if(kind==MessageMediaKind.Image) 32 else null,if(kind==MessageMediaKind.Image) 32 else null)
        val media=MessageMedia(persistentListOf(mediaId),persistentListOf(MessageMediaPresentation(mediaId,kind,type,100,descriptor)))
        database {it.execSQL("UPDATE messages SET media=? WHERE id=?",arrayOf(media.payload().toString(),id.value))}
        return MessageResourceRead(descriptor,MessageResourceSource(room,id,0,1),"A".repeat(32))
    }
    @Test fun fileUsesDatabaseSourceAndNeverClaimsAnActionWithTheWrongMessageProof() {
        val read=mediaRead(MessageMediaKind.File);val selection=MessageFileSelection(MediaMessageLocation(room,id),mediaId)
        var state by mutableStateOf(MessageFileState(selection,true,read.copy(source=read.source.copy(message=MessageId(UUID.randomUUID().toString()))),
            action=TemporaryFileAction("pending","content://fixture/item","text/plain",TemporaryFileMode.Open)))
        var claims=0
        compose.setContent {val open=factory();MaterialTheme {
            MessageFileScreen(app,state,selection,active,{null},{_,_->},{},{},{},claim={claims++;false},openSources=open)
        }}
        awaitSource();compose.onNodeWithText("数据库附件").assertIsDisplayed();compose.onNodeWithText("保存到文件").assertIsNotEnabled();assertEquals(0,claims)
        compose.runOnIdle {state=state.copy(read=read)}
        compose.onNodeWithText("保存到文件").assertIsEnabled();compose.runOnIdle {assertEquals(1,claims);assertTrue(app.snapshot.messages.isEmpty())}
        database {it.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id.value))};refresh()
        compose.onNodeWithText("保存到文件").assertIsNotEnabled();assertEquals(1,claims)
        database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id.value))};refresh()
        compose.onNodeWithText("数据库附件").assertDoesNotExist();compose.onNodeWithText("保存到文件").assertIsNotEnabled()
    }
    @Test fun imageUsesDatabaseSourceAndHidesPixelsOnRevisionAndAccountChanges() {
        val read=mediaRead(MessageMediaKind.Image);val selection=MessageImageSelection(MediaMessageLocation(room,id),mediaId)
        val bytes=com.google.protobuf.ByteString.newOutput();val bitmap=Bitmap.createBitmap(32,32,Bitmap.Config.ARGB_8888)
        try {bitmap.eraseColor(android.graphics.Color.BLUE);bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)} finally {bitmap.recycle()}
        var state by mutableStateOf(MessageImageState(selection,available=true,frame=MessageImageFrame(read,bytes.toByteString(),System.nanoTime()+60_000_000_000,false)))
        compose.setContent {val open=factory();MaterialTheme {MessageImageScreen(app,state,selection,active,{},{},open)}}
        awaitSource();compose.waitUntil(5000) {compose.onAllNodesWithTag("message-image-pixels").fetchSemanticsNodes().isNotEmpty()}
        database {it.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id.value))};refresh()
        compose.onNodeWithTag("message-image-pixels").assertDoesNotExist()
        compose.runOnIdle {state=state.copy(frame=state.frame!!.copy(read=read.copy(source=read.source.copy(revision=2))))}
        compose.waitUntil(5000) {compose.onAllNodesWithTag("message-image-pixels").fetchSemanticsNodes().isNotEmpty()}
        compose.runOnIdle {app=app.copy(session=SessionUi.SignedIn(UserId(UUID.randomUUID().toString())))}
        // This deliberately misconfigured fixture factory still returns the old viewer: the adapter must reject it.
        compose.onNodeWithTag("message-image-pixels").assertDoesNotExist();compose.onNodeWithText("查看原图").assertIsNotEnabled()
    }
    @Test fun playbackUsesDatabaseSourceAndRevocationClosesMetadataOwnership() {
        val read=mediaRead(MessageMediaKind.Audio);val selection=MessagePlaybackSelection(MediaMessageLocation(room,id),mediaId)
        val state=MessagePlaybackState(selection,"sqlite",true,read,System.nanoTime()+60_000_000_000,ready=true,seekable=true,durationMs=8000)
        compose.setContent {val open=factory();MaterialTheme {MessagePlaybackScreen(app,state,selection,active,{null},{},{},{},{},open)}}
        awaitSource();compose.onNodeWithText("数据库附件").assertIsDisplayed();compose.onNodeWithText("播放").assertIsEnabled()
        val previous=page;compose.runOnIdle {active=false};compose.onNodeWithText("播放").assertIsNotEnabled();assertTrue(previous!!.state.value.closed)
        compose.runOnIdle {active=true};awaitSource();assertNotSame(previous,page);compose.onNodeWithText("播放").assertIsEnabled()
        compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.onNodeWithText("数据库附件").assertDoesNotExist();compose.onNodeWithText("播放").assertIsNotEnabled();compose.onNodeWithText("文件操作").assertIsNotEnabled()
        compose.runOnIdle {assertTrue(page!!.state.value.closed);assertTrue(app.snapshot.messages.isEmpty())}
    }

    @Test fun pinsReadOnlyVisibleSourcesAndNavigateByExactMessageId() {
        val ids=(1..60).map {MessageId(UUID(1,it.toLong()).toString())}
        database {db->ids.forEachIndexed {index,message->
            db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,1,1,?,?,0)",
                arrayOf<Any>(message.value,room.value,actor.value,"置顶正文 ${index+1}",index+2,index+2))
        }}
        app=app.copy(snapshot=ClientSnapshot(pins=ids.mapIndexed {index,message->GroupPin(room,message,(60-index).toLong())}.toPersistentList(),
            messages=persistentListOf(Message(ids.first(),room,actor,"全局过期正文",1))))
        var opened: MessageId?=null
        compose.setContent {val open=factory();MaterialTheme {PinsPage(room,app,model,active,open,openMessage={opened=it})}}
        compose.waitUntil(10000) {page?.state?.value?.messages?.containsKey(ids.first())==true}
        compose.onNodeWithText("置顶正文 1").assertIsDisplayed();compose.onNodeWithText("全局过期正文").assertDoesNotExist()
        assertTrue(page!!.state.value.ids.size in 1..10)
        compose.onNode(hasText("打开聊天") and hasAnyAncestor(hasTestTag("pin-${ids.first().value}"))).performClick();assertEquals(ids.first(),opened)
        compose.onNodeWithTag("pins-list").performScrollToNode(hasTestTag("pin-${ids.last().value}"))
        compose.waitUntil(10000) {page?.state?.value?.messages?.containsKey(ids.last())==true}
        compose.onNodeWithText("置顶正文 60").assertIsDisplayed();assertFalse(page!!.state.value.ids.contains(ids.first()))
        database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(ids.last().value))};refresh()
        compose.onNodeWithText("置顶正文 60").assertDoesNotExist()
        compose.onNode(hasText("打开聊天") and hasAnyAncestor(hasTestTag("pin-${ids.last().value}"))).assertIsNotEnabled()
        compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.runOnIdle {assertTrue(page!!.state.value.closed)}
    }

}
