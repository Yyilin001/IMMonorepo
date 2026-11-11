package com.xmtx.im

import android.app.Application
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.semantics.SemanticsActions
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class RichMessageUiTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id())
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun spoilerIsAbsentFromTextAndLinksUntilRevealedAndResetsOnRevisionOrBackground() {
        val message=Message(MessageId(id()),room,actor,"secret link",1,rich=MessageRichContent(entities=persistentListOf(RichTextEntity(0,6,RichTextKind.spoiler),RichTextEntity(0,6,RichTextKind.link,"https://example.test/hidden"),RichTextEntity(7,4,RichTextKind.link,"https://example.test/open"))))
        var current by mutableStateOf(message);var active by mutableStateOf(true);val opened=mutableListOf<String>()
        compose.setContent {CompositionLocalProvider(LocalUriHandler provides object:UriHandler {override fun openUri(uri:String) {opened+=uri}}) {MaterialTheme {RichMessageText(current,active)}}}
        compose.onNodeWithTag("rich-message-${message.id.value}").assertTextEquals("•••••• link")
        val hidden=annotatedMessage(message.text,message.rich!!,false,true,Color.Blue,Color.Gray) {}
        assertEquals(1,hidden.getLinkAnnotations(0,hidden.length).size);assertFalse(hidden.text.contains("secret"))
        var layout:TextLayoutResult?=null
        compose.onNodeWithTag("rich-message-${message.id.value}").performSemanticsAction(SemanticsActions.GetTextLayoutResult) {val result=mutableListOf<TextLayoutResult>();it(result);layout=result.single()}
        compose.onNodeWithTag("rich-message-${message.id.value}").performTouchInput {click(layout!!.getBoundingBox(8).center)}
        compose.runOnIdle {assertEquals(listOf("https://example.test/open"),opened)}
        compose.onNodeWithText("显示隐藏内容").performClick();compose.onNodeWithTag("rich-message-${message.id.value}").assertTextEquals(message.text)
        compose.runOnIdle {active=false};compose.onNodeWithTag("rich-message-${message.id.value}").assertTextEquals("•••••• link")
        compose.runOnIdle {active=true};compose.onNodeWithText("显示隐藏内容").performClick();compose.runOnIdle {current=message.copy(revision=2)}
        compose.onNodeWithTag("rich-message-${message.id.value}").assertTextEquals("•••••• link")
        compose.runOnIdle {current=current.copy(withdrawn=true)};compose.onNodeWithText("消息已撤回").assertExists();compose.onNodeWithText("显示隐藏内容").assertDoesNotExist()
    }
    @Test fun overlappingStylesCombineAndLinksArePartitionedWithoutExposingSpoilerTargets() {
        val rich=MessageRichContent(entities=persistentListOf(RichTextEntity(0,4,RichTextKind.bold),RichTextEntity(0,4,RichTextKind.underline),RichTextEntity(0,4,RichTextKind.strikethrough),RichTextEntity(0,3,RichTextKind.link,"https://example.test/a"),RichTextEntity(2,2,RichTextKind.link,"https://example.test/b")))
        val value=annotatedMessage("text",rich,false,true,Color.Blue,Color.Gray) {}
        assertTrue(value.spanStyles.all {it.item.fontWeight==FontWeight.Bold && it.item.textDecoration==TextDecoration.combine(listOf(TextDecoration.Underline,TextDecoration.LineThrough))})
        val links=value.getLinkAnnotations(0,4);assertEquals(listOf(0,2,3),links.map {it.start});assertEquals(listOf(2,3,4),links.map {it.end})
    }
    @Test fun referencePreviewUsesOnlySameRoomVisibleSourceAndMasksItsSpoiler() {
        val source=Message(MessageId(id()),room,actor,"hidden",1,rich=MessageRichContent(entities=persistentListOf(RichTextEntity(0,6,RichTextKind.spoiler))))
        val response=Message(MessageId(id()),room,actor,"reply",2,rich=MessageRichContent(persistentListOf(MentionTarget.User(actor),MentionTarget.Everyone),replyTo=source.id))
        var target by mutableStateOf<Message?>(source);var jumped=0
        compose.setContent {MaterialTheme {MessageBubbleContent(response,viewer=actor,replySource=target,jumpReply={jumped++})}}
        compose.onNodeWithTag("reply-preview-text",useUnmergedTree=true).assertTextEquals("••••••")
        compose.onNodeWithTag("reply-reference-${response.id.value}").performClick();assertEquals(1,jumped)
        compose.onNodeWithText("@所有人 · 提及了你").assertExists()
        compose.runOnIdle {target=source.copy(roomId=RoomId(id()))};compose.onNodeWithText("回复的消息当前不可用").assertExists();compose.onNodeWithTag("reply-preview-text").assertDoesNotExist()
        compose.runOnIdle {target=source.copy(withdrawn=true)};compose.onNodeWithText("回复的消息当前不可用").assertExists()
    }
    @Test fun actualEditorSelectionPersistsFormattingAcrossRepositoryReopenAndFreezesTheSameSend() {
        val device=DeviceId(id());var store=openBoundFixtureStore(context,actor,device);var files=ManagedResourceFiles(context,store)
        var state by mutableStateOf<ChatComposerState?>(null);var repo:ChatComposerRepository?=null
        var keyboard:androidx.compose.ui.platform.SoftwareKeyboardController?=null;var imeBottom=0
        fun app()=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"内容测试群",kind=RoomKind.Group))),chatComposer=state)
        try {
            compose.runOnIdle {repo=ChatComposerRepository(context,actor,store,files) {state=it};repo!!.foreground(true);repo!!.activate(room)}
            compose.setContent {keyboard=androidx.compose.ui.platform.LocalSoftwareKeyboardController.current;imeBottom=WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current);MaterialTheme {Box(Modifier.fillMaxSize().safeDrawingPadding()) {ComposeContentScreen(app(),room,true,{owner,text,rich->repo!!.editContent(owner,text,rich)},{owner,input->repo!!.mentions(owner,input)})}}}
            compose.waitUntil(5000) {state?.draft!=null}
            compose.onNodeWithTag("rich-draft-input").performTextInput("格式草稿")
            compose.onNodeWithTag("rich-draft-input").performTextInputSelection(TextRange(0,2))
            compose.onNodeWithText("选区格式").performScrollTo().performClick();compose.onNodeWithText("加粗").performClick()
            compose.waitUntil(5000) {state?.draft?.rich?.entities?.size==1}
            compose.onNodeWithTag("rich-draft-input").performTextInputSelection(TextRange(2,4))
            compose.onNodeWithText("选区格式").performScrollTo().performClick();compose.onNodeWithText("链接").performClick()
            compose.onNodeWithTag("rich-link-input").performTextInput("https://中文.test/a b")
            compose.onNodeWithText("应用链接").performClick();compose.waitUntil(5000) {state?.draft?.rich?.entities?.size==2}
            val rich=state!!.rich;assertEquals(RichTextKind.bold,rich.entities.first().kind);assertEquals(2,rich.entities.first().lengthUTF16)
            assertEquals("https://xn--fiq228c.test/a%20b",rich.entities.last().linkURL)
            if(InstrumentationRegistry.getArguments().getString("captureRichEditor")=="true") {
                compose.runOnUiThread {keyboard?.hide()};compose.waitUntil(5000) {imeBottom==0};compose.waitForIdle()
                val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                try {context.openFileOutput("rich-content-editor.png",0).use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}} finally {bitmap.recycle()}
            }
            runBlocking {repo!!.close();files.close();store.close()};store=openBoundFixtureStore(context,actor,device);files=ManagedResourceFiles(context,store)
            assertEquals(rich,runBlocking {store.conversationDraft(room)}.rich)
            compose.runOnIdle {state=null;repo=ChatComposerRepository(context,actor,store,files) {state=it};repo!!.foreground(true);repo!!.activate(room)}
            compose.waitUntil(5000) {state?.draft!=null};compose.runOnIdle {repo!!.send(state!!.id)}
            compose.waitUntil(5000) {state?.feedback=="消息已保存，正在发送"}
            val intent=runBlocking {store.sendIntents().single().intent};assertEquals("格式草稿",intent.text);assertEquals(rich,intent.rich)
        } finally {runBlocking {repo?.close();files.close();store.close()}}
    }
    @Test fun alreadyOpenRichEditorStopsEditsAndReplyChangesWhenSystemClassificationArrives() {
        var state by mutableStateOf(ChatComposerState(id(),room,ConversationDraft(room),text="保留正文",available=true,loading=false,rich=MessageRichContent(replyTo=MessageId(id()))))
        compose.setContent {MaterialTheme {ComposeContentScreen(AppState(SessionUi.SignedIn(actor),chatComposer=state),room,true,{_,text,rich->state=state.copy(text=text,rich=rich)},{_,_->})}}
        compose.onNodeWithTag("rich-draft-input").assertIsEnabled()
        compose.runOnIdle {state=state.copy(directAccountKind=AccountKind.System)}
        compose.onNodeWithText("此系统账号仅用于发送通知").assertExists();compose.onNodeWithTag("rich-draft-input").assertIsNotEnabled()
        compose.onNodeWithText("取消回复").assertIsNotEnabled();compose.runOnIdle {assertEquals("保留正文",state.text);assertNotNull(state.rich.replyTo)}
        compose.runOnIdle {state=state.copy(directAccountKind=AccountKind.CustomerSupport)}
        compose.onNodeWithTag("rich-draft-input").assertIsEnabled();compose.onNodeWithText("取消回复").assertIsEnabled()
        compose.runOnIdle {state=state.copy(canSend=false)};compose.onNodeWithTag("rich-draft-input").assertIsNotEnabled()
    }
    @Test fun mentionInputAndReplyCancellationUseTheCurrentOwnerAndRespectLockedContent() {
        val source=Message(MessageId(id()),room,actor,"引用正文",1)
        var state by mutableStateOf(ChatComposerState(id(),room,ConversationDraft(room),text="draft",available=true,loading=false,rich=MessageRichContent(replyTo=source.id)))
        var active by mutableStateOf(true);var received:String?=null
        compose.setContent {val scope=rememberCoroutineScope();MaterialTheme {ComposeContentScreen(AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"群",kind=RoomKind.Group)),messages=persistentListOf(source)),chatComposer=state),room,active,
            {owner,text,rich->assertEquals(state.id,owner);state=state.copy(text=text,rich=rich)},
            {owner,input->assertEquals(state.id,owner);received=input;state=state.copy(rich=state.rich.copy(mentions=runBlocking {resolveChatMentions(input,true) {actor}}))},openSources={MessageSourceSession(messageSourceFixture(actor,source),room,actor,scope)})}}
        compose.waitUntil(5000) {compose.onAllNodesWithText("引用正文").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("取消回复").performScrollTo().performClick();compose.runOnIdle {assertNull(state.rich.replyTo)}
        compose.onNodeWithTag("mention-handles").performScrollTo().performTextInput("member,@all")
        compose.onNodeWithText("应用提及").performScrollTo().performClick();compose.runOnIdle {assertEquals("member,@all",received)}
        compose.onNodeWithTag("draft-mentions").performScrollTo().assertTextEquals("@所有人 · 提及 1 位成员")
        compose.runOnIdle {state=state.copy(contentLocked=true)};compose.onNodeWithText("清除提及").assertIsNotEnabled()
        compose.runOnIdle {state=state.copy(contentLocked=false);active=false};compose.onNodeWithText("应用提及").assertIsNotEnabled()
    }
    @Test fun chatMessageMenuOffersReplyOnlyForAnAcceptedVisibleMessage() {
        val source=Message(MessageId(id()),room,actor,"回复这一条",1)
        var message by mutableStateOf(source);var replied:MessageId?=null;var composerState by mutableStateOf<ChatComposerState?>(null)
        compose.setContent {MaterialTheme {Chat(AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"群",kind=RoomKind.Group)),messages=persistentListOf(message)),chatComposer=composerState),SessionUi.SignedIn(actor),room,{_,_->true},reply={replied=it})}}
        compose.onNodeWithText("消息操作").performClick();compose.onNodeWithText("回复消息").performClick();compose.runOnIdle {assertEquals(source.id,replied);composerState=ChatComposerState(id(),room,directAccountKind=AccountKind.System)}
        compose.onNodeWithText("消息操作").performClick();compose.onNodeWithText("回复消息").assertIsNotEnabled()
        compose.runOnIdle {message=source.copy(withdrawn=true)}
        compose.onNodeWithText("消息操作").assertDoesNotExist();compose.onNodeWithText("回复这一条").assertDoesNotExist()
    }
    @Test fun replyReferenceScrollsTheActualChatTimelineToItsVisibleSource() {
        val source=Message(MessageId(id()),room,actor,"原始消息",1)
        val response=Message(MessageId(id()),room,actor,"最后的回复",30,rich=MessageRichContent(replyTo=source.id))
        val messages=(listOf(source)+(1..20).map {Message(MessageId(id()),room,actor,"中间消息 $it",it.toLong()+1)}+response).toPersistentList()
        compose.setContent {MaterialTheme {Chat(AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"群")),messages=messages)),SessionUi.SignedIn(actor),room,{_,_->true})}}
        compose.waitUntil(5000) {compose.onAllNodesWithTag("reply-reference-${response.id.value}").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("reply-reference-${response.id.value}").performClick()
        compose.onNodeWithTag("rich-message-${source.id.value}").assertIsDisplayed()
    }
    @Test fun sharedNav3ContentEntryRestoresOnlyRoomIdAndReturnsToTheChatDraft() {
        val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("rich",model)};val restore=StateRestorationTester(compose)
        val app=AppState(SessionUi.SignedIn(actor),ClientSnapshot(conversations=persistentListOf(Conversation(room,"编辑测试群",kind=RoomKind.Group))))
        lateinit var stack:NavBackStack<NavKey>
        try {
            restore.setContent {stack=rememberNavBackStack(Route.Home);MaterialTheme {SignedIn(app,SessionUi.SignedIn(actor),model,stack)}}
            compose.onNodeWithText("编辑测试群").performClick();compose.onNodeWithText("发送消息…").performTextInput("返回保留正文")
            compose.runOnIdle {stack.add(Route.ComposeContent(room.value))};compose.onNodeWithText("编辑消息内容").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restore.emulateSavedInstanceStateRestore();compose.onNodeWithText("编辑消息内容").assertIsDisplayed()
            val route:Route=Route.ComposeContent(room.value);val encoded=Json.encodeToString(route);assertEquals(route,Json.decodeFromString<Route>(encoded));assertFalse(encoded.contains("正文"))
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("返回保留正文").assertExists()
        } finally {compose.runOnUiThread {owners.clear()}}
    }
}
