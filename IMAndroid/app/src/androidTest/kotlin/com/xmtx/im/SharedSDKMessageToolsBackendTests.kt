package com.xmtx.im

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.sharedsdk.*
import com.xmtx.im.swiftplatform.AndroidRuntimePlatform
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.net.Socket
import java.util.UUID

class SharedSDKMessageToolsBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun searchMutationAndReadReceiptsUseSharedRuntime() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments(); org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base=args.getString("sharedURL")!!; val port=args.getString("sharedTLSPort")!!.toInt(); val peerPort=args.getString("sharedPeerTLSPort")!!.toInt(); val control=args.getString("sharedControlPort")!!.toInt()
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-", "").take(10); val password=UUID.randomUUID().toString()+"aA1!"
        val names=listOf("phase10_${run}_a","phase10_${run}_b","phase10_${run}_c"); val fixture=SharedBackendFixture(base); val accounts=names.map { fixture.register(it,password) }
        val room=fixture.direct(accounts[1],accounts[0]); val peer=SharedClient.open(context,SharedEndpoint(base,"localhost",peerPort))
        var peerJob: Job?=null; var scenario: ActivityScenario<MainActivity>?=null; var model: SharedAppViewModel?=null
        val evidence=JSONObject().put("phase",10).put("realBackend",true).put("roomID",room).put("appEntry","MainActivity")
        fun snap()=model!!.state.value.snapshot!!
        fun idle() { compose.waitUntil(30000) { model != null && !model!!.state.value.busy } }
        fun click(tag:String,list:String?=null) { idle(); if(list!=null) compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag)); compose.onNodeWithTag(tag).assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick) { it() } }
        fun stage(name:String) { File(context.filesDir,"phase10-progress.json").writeText(evidence.put("lastStage",name).toString()) }
        fun launchApp() { scenario=ActivityScenario.launch(MainActivity::class.java);scenario!!.onActivity { model=ViewModelProvider(it)[SharedAppViewModel::class.java] };idle() }
        fun login(index:Int) { compose.onNodeWithTag("shared_account").performTextReplacement(names[index]);compose.onNodeWithTag("shared_password").performTextInput(password);click("shared_login");compose.waitUntil(60000) { snap().state==SharedSessionState.Connected } }
        fun openChat(id:String=room) { compose.waitUntil(45000) { snap().conversations.any { it.id==id } };click("shared_room_$id","shared_conversations");compose.waitUntil(30000) { snap().chat?.roomID==id } }
        fun relay(command:String)=Socket("localhost",control).use { it.soTimeout=5000;it.outputStream.write((command+"\n").toByteArray());assertEquals("OK",it.inputStream.bufferedReader().readLine()) }
        suspend fun peerMessage(text:String):SharedMessage=withTimeout(60000) { while(true) { peer.snapshot().chat?.messages?.firstOrNull { it.text==text }?.let { return@withTimeout it };delay(100) };error("unreachable") }
        fun appMessage(text:String):SharedMessage { compose.waitUntil(60000) { snap().chat?.messages?.any { it.text==text }==true };return snap().chat!!.messages.first { it.text==text } }
        fun send(text:String) { idle();compose.onNodeWithTag("shared_composer").performTextReplacement(text);click("shared_send");appMessage(text) }
        fun search(query:String) { idle();compose.onNodeWithTag("shared_search_query").performTextReplacement(query);click("shared_search_submit");compose.waitUntil(45000) { snap().messaging?.search?.let { it.query==query && it.status=="ready" }==true } }
        try {
            peer.login(names[1],password);peerJob=launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(60000) { while(true) { try { peer.openConversation(room);break } catch (_:SharedSdkException) { delay(200) } } }
            SharedAppSettings.save(context,SharedEndpoint(base,"localhost",port));launchApp();login(0)
            stage("friendship")
            peer.socialAction(accounts[0].userID,SharedSocialAction.Request)
            withTimeout(45000) { while(peer.snapshot().directory!!.works.none { it.kind=="relationship" && it.status=="committed" }) delay(100) }
            compose.runOnIdle { model!!.socialAction(accounts[1].userID,SharedSocialAction.Accept) };idle()
            compose.waitUntil(45000) { snap().directory!!.works.any { it.kind=="relationship" && it.status=="committed" } }
            withTimeout(45000) { while(peer.contacts(SharedContactScope.Accepted).directory!!.contacts.none { it.userID==accounts[0].userID }) delay(100) }
            peer.sendText(room,"跨端定位汉字🦊 $run");val anchor=peerMessage("跨端定位汉字🦊 $run")
            for(index in 1..26) peer.sendText(room,"跨端分页 $run 第$index 条")
            for(index in 1..33) peer.sendText(room,"后续消息 $run $index")
            peer.sendText(room,"可见尾部 $run");val tail=peerMessage("可见尾部 $run")
            stage("search")
            click("shared_search_all");search("跨端分页")
            assertEquals(20,snap().messaging!!.search!!.hits.size);assertTrue(snap().messaging!!.search!!.hasNext)
            val first=snap().messaging!!.search!!.hits.map { it.id }.toSet();click("shared_search_next","shared_search_results");idle()
            assertEquals(6,snap().messaging!!.search!!.hits.size);assertTrue(snap().messaging!!.search!!.hits.none { it.id in first })
            search("跨端定位");assertEquals(anchor.id,snap().messaging!!.search!!.hits.single().id)
            delay(800);assertFalse(peer.snapshot().chat!!.messages.first { it.id==tail.id }.readByPeer)
            evidence.put("unicodeGlobalSearchAndPagination",true).put("searchDoesNotPublishRead",true).put("anchorMessageID",anchor.id)
            click("shared_search_hit_${anchor.id}","shared_search_results");compose.waitUntil(30000) { snap().chat?.focusMessageID==anchor.id }
            compose.onNodeWithTag("shared_message_${anchor.id}").assertIsDisplayed();assertFalse(snap().chat!!.isLatest)
            delay(800);assertFalse(peer.snapshot().chat!!.messages.first { it.id==tail.id }.readByPeer)
            compose.onNodeWithText("最新消息").performClick();compose.waitUntil(15000) { snap().chat!!.isLatest }
            compose.onNodeWithTag("shared_messages").performScrollToNode(hasTestTag("shared_message_${tail.id}"))
            withTimeout(45000) { while(peer.snapshot().chat!!.messages.first { it.id==tail.id }.readByPeer.not()) delay(100) }
            evidence.put("searchAnchorOutsideLatest50",true).put("viewportReadReceipt",true)
            stage("edit")
            send("编辑原文 $run");val original=peerMessage("编辑原文 $run")
            peer.markVisibleMessages(room,listOf(original.id));compose.waitUntil(45000) { snap().chat!!.messages.first { it.id==original.id }.readByPeer }
            click("shared_edit_${original.id}","shared_messages");compose.onNodeWithTag("shared_edit_text").performTextReplacement("修改完成汉字 $run");click("shared_edit_confirm")
            val edited=peerMessage("修改完成汉字 $run");assertEquals(original.id,edited.id);assertEquals(2L,edited.revision)
            compose.waitUntil(30000) { snap().chat!!.messages.any { it.id==edited.id && it.revision==2L } }
            assertTrue(runCatching { peer.editMessage(room,edited.id,edited.revision,"unauthorized") }.isFailure)
            click("shared_search_room");search("编辑原文");assertTrue(snap().messaging!!.search!!.hits.isEmpty())
            search("修改完成汉字");assertEquals(edited.id,snap().messaging!!.search!!.hits.single().id)
            click("shared_search_hit_${edited.id}","shared_search_results");compose.waitUntil(30000) { snap().chat?.focusMessageID==edited.id }
            click("shared_withdraw_${edited.id}","shared_messages");click("shared_withdraw_confirm")
            withTimeout(45000) { while(peer.snapshot().chat!!.messages.none { it.id==edited.id && it.withdrawn && it.text.isEmpty() && it.revision==3L }) delay(100) }
            compose.waitUntil(30000) { snap().chat!!.messages.any { it.id==edited.id && it.withdrawn } }
            click("shared_search_room");search("修改完成汉字");assertTrue(snap().messaging!!.search!!.hits.isEmpty());compose.onNodeWithText("返回").performClick()
            evidence.put("editedMessageID",edited.id).put("editAndWithdrawalPeerSync",true).put("searchRemovesOldAndWithdrawnText",true).put("otherSenderMutationRejected",true)
            stage("reopen")
            compose.runOnIdle { model!!.markVisibleMessages(room,listOf(edited.id)) };idle();assertNull(model!!.state.value.error)
            evidence.put("withdrawnViewportDoesNotFail",true)
            send("恢复编辑原文 $run");val recovering=peerMessage("恢复编辑原文 $run")
            stage("reopen-pause");relay("pause");compose.waitUntil(20000) { snap().state!=SharedSessionState.Connected }
            stage("reopen-edit");click("shared_edit_${recovering.id}","shared_messages");compose.onNodeWithTag("shared_edit_text").performTextReplacement("恢复编辑完成 $run");click("shared_edit_confirm");idle()
            stage("reopen-close");scenario!!.close();scenario=null;withTimeout(30000) { while(SharedClient.activeClientCount()!=1) delay(50) }
            stage("reopen-restore");relay("resume");launchApp();compose.waitUntil(60000) { snap().state==SharedSessionState.Connected };openChat()
            val recovered=appMessage("恢复编辑完成 $run");assertEquals(recovering.id,recovered.id);assertEquals(2L,recovered.revision)
            assertEquals(2L,peerMessage("恢复编辑完成 $run").revision)
            evidence.put("recoveredEditMessageID",recovered.id).put("offlineEditOwnerReopenSingleRevision",true)
            stage("group")
            peer.createGroup("已读群 $run",listOf(accounts[0].userID))
            val group=withTimeout(60000) { while(true) { peer.snapshot().directory!!.works.firstOrNull { it.kind=="groupRoom" && it.status=="committed" }?.roomID?.let { return@withTimeout it };delay(100) };error("unreachable") }
            click("shared_chat_back");openChat(group)
            send("群已读消息 $run");val groupMessage=appMessage("群已读消息 $run")
            withTimeout(45000) { while(true) { try { peer.openConversation(group);break } catch (_:SharedSdkException) { delay(100) } } }
            peerMessage("群已读消息 $run");peer.markVisibleMessages(group,listOf(groupMessage.id))
            click("shared_readers_${groupMessage.id}","shared_messages")
            compose.waitUntil(30000) { snap().messaging?.readers!=null }
            if(snap().messaging!!.readers!!.users.none { it==accounts[1].userID }) { delay(1000);click("shared_readers_refresh") }
            compose.waitUntil(30000) { snap().messaging?.readers?.users?.contains(accounts[1].userID)==true }
            compose.onNodeWithTag("shared_reader_${accounts[1].userID}").assertExists()
            evidence.put("groupID",group).put("groupMessageID",groupMessage.id).put("groupReadDetail",true)
            stage("isolation")
            idle();compose.runOnIdle { model!!.signOut() };compose.waitUntil(30000) { model!!.state.value.snapshot?.userID==null && !model!!.state.value.busy };login(2)
            assertNull(snap().messaging!!.search);assertNull(snap().messaging!!.readers);assertTrue(snap().messaging!!.mutations.isEmpty());assertNull(snap().chat)
            click("shared_search_all");search("跨端");assertTrue(snap().messaging!!.search!!.hits.isEmpty())
            idle();compose.runOnIdle { model!!.signOut() };compose.waitUntil(30000) { model!!.state.value.snapshot?.userID==null && !model!!.state.value.busy }
            scenario!!.close();scenario=null;peerJob!!.cancelAndJoin();peerJob=null;peer.signOut();peer.close()
            assertEquals(0,SharedClient.activeClientCount());assertEquals(0,SharedClient.activeOperationCount());assertEquals(0,AndroidRuntimePlatform.install(context).activeHttpCount);assertEquals(0,AndroidRuntimePlatform.install(context).activeConnectionCount)
            File(context.filesDir,"shared-sdk-evidence.json").writeText(evidence.put("passed",true).put("accountIsolation",true).put("leakedClients",0).put("leakedOperations",0).toString(2))
        } finally { scenario?.close();peerJob?.cancelAndJoin();peer.close() }
    }
}
