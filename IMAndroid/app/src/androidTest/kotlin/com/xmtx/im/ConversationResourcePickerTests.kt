package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.navigation3.runtime.*
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ConversationResourcePickerTests {
    @get:Rule val compose=createComposeRule()
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id());private val media=id()
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),media),1,"项目说明.pdf","application/pdf",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private val selection=MessageAttachmentSelection(descriptor,MessageResourceSource(room,MessageId(id()),0,1))
    private val page=ResourceCatalogPage(persistentListOf(ResourceCatalogEntry(descriptor,1000,1)),null,false)
    private fun picker()=ConversationResourcePickerState("picker",room,available=true,entries=page.entries)
    private fun app()=AppState(session=SessionUi.SignedIn(actor),chatComposer=ChatComposerState("composer",room,ConversationDraft(room),available=true,loading=false))
    private suspend fun until(body: ()->Boolean) {withTimeout(5000) {while(!body()) delay(10)}}
    @Test fun composerPersistsImportedOnlyDraftAndFreezesItWithTextAndOrder()=runBlocking {
        val store=openBoundFixtureStore(InstrumentationRegistry.getInstrumentation().targetContext,actor,DeviceId(id()))
        store.acceptState(room,com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build())
        store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(selection.source.message,1,RoomResourcePosition(1,0,media),1000,descriptor)),100,null))
        val sends=SendIntentService(actor,store)
        val controller=ChatComposerController(room,this,store,{_,_->error("must prepare whole draft")},{error("no local staging")},{},
            {draft->draft.imports.filterNot {store.isConversationResourceCurrent(it.selection)}.map {it.id}.toPersistentSet()},{},importDrafts=store,prepareDraft=sends::prepareDraft)
        try {
            controller.foreground(true);until {controller.state.draft!=null};controller.edit("保留正文")
            controller.addImported(selection);controller.addImported(selection);assertTrue(store.resourceImports().isEmpty());assertEquals(2,controller.state.resources.size)
            val first=controller.state.resources.first().id;controller.move(first,1);until {controller.state.resources.last().id==first}
            controller.send();until {!controller.state.sending};assertEquals(1,store.sendIntents().size)
            val intent=store.sendIntents().single().intent;assertEquals("保留正文",intent.text);assertEquals(first,intent.attachmentOrder.last());assertEquals(2,intent.serverImports.size)
            assertTrue(controller.state.resources.isEmpty());assertEquals(2,store.resourceImports().size)
        } finally {controller.close();store.close()}
    }
    @Test fun selectionRequiresExplicitConfirmationAndRevocationClearsIt()=runBlocking {
        val changes=MutableStateFlow(0L);var valid=true;var writes=0;val queries=mutableListOf<ResourceCatalogQuery>()
        val controller=ConversationResourcePickerController("picker",room,this,changes,{queries.add(it);page},{selection},{valid},{writes++},{})
        try {
            controller.foreground(true);until {!controller.state.loading};controller.choose(selection.key);until {controller.state.selected!=null};assertEquals(0,writes)
            valid=false;changes.value++;until {controller.state.selected==null};controller.confirm();assertEquals(0,writes)
            valid=true;controller.search("项目",ResourceCategory.File);until {!controller.state.loading};assertEquals(ResourceCategory.File,queries.last().category)
            controller.choose(selection.key);until {controller.state.selected!=null};controller.confirm();controller.confirm();until {controller.state.added};assertEquals(1,writes)
        } finally {controller.close()}
    }
    @Test fun cancelledReadAndCommittedLateAddCannotReviveClosedPage()=runBlocking {
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var writes=0
        val controller=ConversationResourcePickerController("picker",room,this,MutableStateFlow(0L),{page},{selection},{true},
            {entered.complete(Unit);withContext(NonCancellable) {release.await();writes++}},{})
        try {
            controller.foreground(true);until {!controller.state.loading};controller.choose(selection.key);until {controller.state.selected!=null}
            controller.confirm();entered.await();controller.close();release.complete(Unit);until {writes==1};delay(20)
            assertFalse(controller.state.added);assertNull(controller.state.selected);assertFalse(controller.state.available)
        } finally {release.complete(Unit);controller.close()}
    }
    @Test fun confirmationAddsToDraftAndCapacityOrRevocationDisablesIt() {
        var state by mutableStateOf(picker());var app by mutableStateOf(app());var writes=0
        compose.setContent {MaterialTheme {ConversationResourcePickerScreen(app,state,true,{_,_->},{},{},{state=state.copy(selected=selection)},{writes++},{state=state.copy(selected=null)})}}
        compose.onNodeWithTag("conversation-resource-$media").performClick();compose.runOnIdle {assertEquals(0,writes)}
        compose.onNodeWithText("添加到当前聊天草稿？").assertIsDisplayed();compose.onNodeWithText("添加到草稿").assertIsEnabled()
        if(InstrumentationRegistry.getArguments().getString("captureConversationResources")=="true") {
            val instrumentation=InstrumentationRegistry.getInstrumentation();val image=instrumentation.uiAutomation.takeScreenshot()
            try {instrumentation.targetContext.openFileOutput("conversation-resources-confirm.png",0).use {image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}} finally {image.recycle()}
        }
        compose.runOnIdle {app=app.copy(chatComposer=app.chatComposer!!.copy(directAccountKind=AccountKind.System))}
        compose.onNodeWithText("添加到草稿").assertIsNotEnabled()
        compose.runOnIdle {app=app.copy(chatComposer=app.chatComposer!!.copy(directAccountKind=AccountKind.CustomerSupport))}
        compose.onNodeWithText("添加到草稿").assertIsEnabled()
        compose.runOnIdle {app=app.copy(chatComposer=app.chatComposer!!.copy(canSend=false))}
        compose.onNodeWithText("添加到草稿").assertIsNotEnabled()
        compose.runOnIdle {app=app.copy(chatComposer=app.chatComposer!!.copy(canSend=true))}
        compose.onNodeWithText("添加到草稿").performClick();compose.runOnIdle {assertEquals(1,writes);app=app.copy(chatComposer=app.chatComposer!!.copy(contentLocked=true))}
        compose.onNodeWithText("添加到草稿").assertIsNotEnabled()
        compose.runOnIdle {app=app.copy(snapshot=app.snapshot.copy(revokedRooms=persistentSetOf(room)))}
        compose.onNodeWithText("添加到草稿").assertDoesNotExist();compose.onNodeWithTag("conversation-resource-$media").assertIsNotEnabled()
    }
    @Test fun sharedStackRestoresTargetAndReturnsToChatWithItsDraft() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext;val model=AppViewModel(context.applicationContext as Application);val owners=ViewModelStore().apply {put("resource",model)}
        val state=app().copy(conversationResources=picker(),snapshot=ClientSnapshot(conversations=persistentListOf(Conversation(room,"附件会话",kind=RoomKind.Group))))
        lateinit var stack:NavBackStack<NavKey>;val restoration=StateRestorationTester(compose)
        try {
            restoration.setContent {stack=rememberNavBackStack(Route.Home);MaterialTheme {SignedIn(state,SessionUi.SignedIn(actor),model,stack)}}
            compose.onNodeWithText("附件会话").performClick();compose.onNodeWithText("发送消息…").performTextInput("选择后继续写")
            compose.runOnIdle {stack.add(Route.ConversationResources(room.value,"picker"))};compose.onNodeWithText("添加聊天附件").assertIsDisplayed();compose.onNodeWithText("我的").assertDoesNotExist()
            restoration.emulateSavedInstanceStateRestore();compose.runOnIdle {assertEquals(Route.ConversationResources(room.value,"picker"),stack.last())}
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("选择后继续写").assertIsDisplayed()
        } finally {compose.runOnUiThread {owners.clear()}}
    }
    @Test fun importedDraftRowsHaveSharedOrderingRemovalAndSendEnablement() {
        val transfer=SendImportedAttachment(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.Attachment(room),id()))
        val imported=ConversationImportedAttachment(transfer,selection);val local=SendAttachment(id(),id(),"本地.txt","text/plain",10)
        var state by mutableStateOf(ChatComposerState("composer",room,ConversationDraft(room,attachments=persistentListOf(local),imports=persistentListOf(imported),attachmentOrder=persistentListOf(imported.id,local.id)),available=true,loading=false))
        var moved:String?=null;var removed:String?=null;var opened=0
        compose.setContent {MaterialTheme {ChatComposerBar(room,state,true,{_,_->},{false},{_,_->},{},{_,asset->removed=asset},{},{},move={_,asset,_->moved=asset},openChatResources={opened++})}}
        compose.onNodeWithText("项目说明.pdf").assertExists();compose.onNodeWithContentDescription("发送").assertIsEnabled()
        compose.onNodeWithTag("draft-move-back-${imported.id}").assertIsNotEnabled();compose.onNodeWithTag("draft-move-forward-${imported.id}").performClick()
        compose.onNodeWithTag("remove-attachment-${imported.id}").performClick();compose.runOnIdle {assertEquals(imported.id,moved);assertEquals(imported.id,removed)}
        compose.onNodeWithContentDescription("添加附件").performClick();compose.onNodeWithText("从聊天附件选择").performClick();compose.runOnIdle {assertEquals(1,opened)}
    }
}
