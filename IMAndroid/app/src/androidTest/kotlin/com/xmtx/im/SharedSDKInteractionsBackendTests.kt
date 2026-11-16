package com.xmtx.im

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
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
import java.io.ByteArrayInputStream
import java.io.File
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID

class SharedSDKInteractionsBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun repliesAndForwardingUseSharedRuntime() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments(); org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base=args.getString("sharedURL")!!; val port=args.getString("sharedTLSPort")!!.toInt(); val peerPort=args.getString("sharedPeerTLSPort")!!.toInt(); val control=args.getString("sharedControlPort")!!.toInt()
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val run=UUID.randomUUID().toString().replace("-", "").take(10); val password=UUID.randomUUID().toString()+"aA1!"
        val names=listOf("phase11_${run}_a","phase11_${run}_b","phase11_${run}_c"); val fixture=SharedBackendFixture(base); val accounts=names.map { fixture.register(it,password) }
        val room=fixture.direct(accounts[1],accounts[0]); val peer=SharedClient.open(context,SharedEndpoint(base,"localhost",peerPort))
        var peerJob: Job?=null; var scenario: ActivityScenario<MainActivity>?=null; var model: SharedAppViewModel?=null
        val evidence=JSONObject().put("phase",11).put("realBackend",true).put("roomID",room).put("appEntry","MainActivity")
        fun snap()=model!!.state.value.snapshot!!
        fun idle() { compose.waitUntil(30000) { model != null && !model!!.state.value.busy } }
        fun click(tag:String,list:String?=null) { idle(); if(list!=null) { compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag)) };compose.onNodeWithTag(tag).assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick) { it() } }
        fun stage(name:String) { File(context.filesDir,"phase11-progress.json").writeText(evidence.put("lastStage",name).toString()) }
        fun launchApp() { scenario=ActivityScenario.launch(MainActivity::class.java);scenario!!.onActivity { model=ViewModelProvider(it)[SharedAppViewModel::class.java] };idle() }
        fun login(index:Int) { compose.onNodeWithTag("shared_account").performTextReplacement(names[index]);compose.onNodeWithTag("shared_password").performTextInput(password);click("shared_login");compose.waitUntil(60000) { model!!.state.value.snapshot?.state==SharedSessionState.Connected } }
        fun openChat(id:String=room) {
            compose.waitUntil(45000) { snap().conversations.any { it.id==id } }
            // The summary can arrive before the separate local permission projection.
            // Retry the UI action only for that explicit transient rejection; keep a deadline.
            val deadline=android.os.SystemClock.elapsedRealtime()+45000
            do {
                click("shared_room_$id","shared_conversations");idle()
                if (snap().chat?.roomID==id) break
                assertEquals("内容或权限已变化，请刷新后重试",model!!.state.value.error)
                Thread.sleep(100)
            } while(android.os.SystemClock.elapsedRealtime()<deadline)
            assertNull(model!!.state.value.error);assertEquals(id,snap().chat?.roomID)
        }
        fun relay(command:String)=Socket("localhost",control).use { it.soTimeout=5000;it.outputStream.write((command+"\n").toByteArray());assertEquals("OK",it.inputStream.bufferedReader().readLine()) }
        suspend fun peerMessage(text:String):SharedMessage=withTimeout(60000) { while(true) { peer.snapshot().chat?.messages?.firstOrNull { it.text==text }?.let { return@withTimeout it };delay(100) };error("unreachable") }
        fun appMessage(text:String):SharedMessage { compose.waitUntil(60000) { snap().chat?.messages?.any { it.text==text }==true };return snap().chat!!.messages.first { it.text==text } }
        fun reply(id:String,text:String) { click("shared_reply_$id","shared_messages");compose.onNodeWithTag("shared_reply_text").performTextReplacement(text);click("shared_reply_send");idle() }
        fun forward(message:SharedMessage,target:String) { click("shared_forward_${message.id}","shared_messages");click("shared_forward_target_$target","shared_forward_targets");click("shared_forward_confirm");idle();assertNull(model!!.state.value.error) }
        fun forwardsDone(count:Int) { compose.waitUntil(60000) { snap().messaging!!.interactions.forwards.count { it.status=="committed" && it.succeeded==1 && it.rejected==0 }==count } }
        try {
            peer.login(names[1],password);peerJob=launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(60000) { while(true) { try { peer.openConversation(room);break } catch (_:SharedSdkException) { delay(100) } } }
            SharedAppSettings.save(context,SharedEndpoint(base,"localhost",port));launchApp();login(0)
            stage("friendship")
            peer.socialAction(accounts[0].userID,SharedSocialAction.Request)
            withTimeout(45000) { while(peer.snapshot().directory!!.works.none { it.kind=="relationship" && it.status=="committed" }) delay(100) }
            compose.runOnIdle { model!!.socialAction(accounts[1].userID,SharedSocialAction.Accept) };idle()
            compose.waitUntil(45000) { snap().directory!!.works.any { it.kind=="relationship" && it.status=="committed" } }
            withTimeout(45000) { while(peer.contacts(SharedContactScope.Accepted).directory!!.contacts.none { it.userID==accounts[0].userID }) delay(100) }
            peer.createGroup("转发目标 $run",listOf(accounts[0].userID))
            val group=withTimeout(60000) { while(true) { peer.snapshot().directory!!.works.firstOrNull { it.kind=="groupRoom" && it.status=="committed" }?.roomID?.let { return@withTimeout it };delay(100) };error("unreachable") }
            evidence.put("groupID",group)
            peer.sendText(room,"引用原文汉字🦊 $run");val original=peerMessage("引用原文汉字🦊 $run")
            compose.waitUntil(45000) { snap().conversations.any { it.id==room && it.preview==original.text } }
            openChat();appMessage(original.text);stage("reply")
            reply(original.id,"回复内容 $run");val answer=peerMessage("回复内容 $run")
            assertEquals(original.id,answer.replyToID);assertEquals(original.text,answer.replyPreview)
            val ownAnswer=appMessage(answer.text);assertEquals(original.id,ownAnswer.replyToID)
            click("shared_reply_reference_${answer.id}","shared_messages");compose.waitUntil(30000) { snap().chat?.focusMessageID==original.id }
            compose.onNodeWithTag("shared_message_${original.id}").assertIsDisplayed()
            evidence.put("sourceMessageID",original.id).put("replyMessageID",answer.id).put("replyReferenceAndNavigation",true)
            stage("text-forward")
            forward(original,group);forwardsDone(1);peer.openConversation(group)
            val forwarded=peerMessage(original.text);assertEquals(original.id,forwarded.forwardedFromID);assertNotEquals(original.id,forwarded.id)
            evidence.put("forwardedTextMessageID",forwarded.id).put("textForwardedWithAttribution",true)
            peer.openConversation(room);peer.editMessage(room,original.id,original.revision,"更新原文 $run");val changed=peerMessage("更新原文 $run")
            assertTrue(runCatching { peer.forwardMessage(room,original.id,original.revision,group) }.isFailure)
            compose.waitUntil(45000) { snap().chat!!.messages.first { it.id==answer.id }.replyPreview==changed.text }
            evidence.put("staleForwardRevisionRejected",true).put("replyPreviewRefreshes",true)
            stage("file-forward")
            val bytes=ByteArray(16384) { (it % 251).toByte() }
            val draft=peer.importAttachment(room,"forward-file.bin","application/octet-stream",ByteArrayInputStream(bytes)).resource!!.draft!!
            peer.sendAttachment(room,draft.id,"转发附件 $run");val file=peerMessage("转发附件 $run");appMessage(file.text)
            forward(file,group);forwardsDone(2);peer.openConversation(group)
            val forwardedFile=peerMessage(file.text);assertEquals(file.id,forwardedFile.forwardedFromID);assertEquals(1,forwardedFile.attachments.size)
            stage("file-download")
            click("shared_chat_back");openChat(group);appMessage(file.text)
            click("shared_attachment_${forwardedFile.attachments.single().id}","shared_messages");click("shared_resource_download","shared_resource_detail")
            compose.waitUntil(60000) { snap().resource!!.transfers.any { it.kind=="download" && it.phase=="completed" && it.bytes==bytes.size.toLong() } }
            val output=File(context.cacheDir,"phase11-forward-export.bin")
            val instrumentation=InstrumentationRegistry.getInstrumentation()
            val save=instrumentation.addMonitor(IntentFilter(Intent.ACTION_CREATE_DOCUMENT).apply { addDataType("application/octet-stream");addCategory(Intent.CATEGORY_OPENABLE) },Instrumentation.ActivityResult(Activity.RESULT_OK,Intent().setData(Uri.fromFile(output))),true)
            try { click("shared_resource_save","shared_resource_detail");compose.waitUntil(15000) { save.hits>0 } } finally { instrumentation.removeMonitor(save) }
            compose.waitUntil(15000) { output.exists() && output.length()==bytes.size.toLong() };assertArrayEquals(bytes,output.readBytes())
            evidence.put("fileSourceMessageID",file.id).put("forwardedFileMessageID",forwardedFile.id).put("forwardedFileMediaID",forwardedFile.attachments.single().id).put("fileForwardDownloadSHA256",MessageDigest.getInstance("SHA-256").digest(output.readBytes()).joinToString("") { "%02x".format(it) })
            compose.onNodeWithText("返回").performClick();click("shared_chat_back");openChat()
            peer.openConversation(room);stage("reopen")
            relay("pause");compose.waitUntil(20000) { snap().state!=SharedSessionState.Connected }
            reply(original.id,"离线回复 $run");forward(changed,group)
            scenario!!.close();scenario=null;withTimeout(30000) { while(SharedClient.activeClientCount()!=1) delay(50) }
            relay("resume");launchApp();compose.waitUntil(60000) { model!!.state.value.snapshot?.state==SharedSessionState.Connected };openChat()
            val restoredReply=appMessage("离线回复 $run");assertEquals(original.id,restoredReply.replyToID);assertEquals(restoredReply.id,peerMessage(restoredReply.text).id)
            forwardsDone(3)
            peer.openConversation(group);val restoredForward=peerMessage(changed.text);assertEquals(original.id,restoredForward.forwardedFromID)
            assertEquals(1,peer.snapshot().chat!!.messages.count { it.text==changed.text });assertEquals(3,peer.snapshot().chat!!.messages.count { it.forwardedFromID!=null })
            evidence.put("restoredReplyMessageID",restoredReply.id).put("restoredForwardMessageID",restoredForward.id).put("disconnectOwnerReopenNoDuplicates",true)
            stage("withdrawn-reference")
            peer.openConversation(room);peer.withdrawMessage(room,original.id,changed.revision)
            compose.waitUntil(45000) { snap().chat!!.messages.first { it.id==original.id }.withdrawn && snap().chat!!.messages.first { it.id==answer.id }.replyPreview==null }
            compose.onNodeWithTag("shared_messages").performScrollToNode(hasTestTag("shared_reply_reference_${answer.id}"))
            compose.onNodeWithTag("shared_reply_reference_${answer.id}").assertIsNotEnabled()
            withTimeout(45000) { while(peer.snapshot().chat!!.messages.none { it.id==original.id && it.withdrawn }) delay(100) }
            assertTrue(runCatching { peer.sendText(room,"invalid reply",original.id) }.isFailure)
            evidence.put("withdrawnReferenceRedactedAndActionsRejected",true)
            stage("isolation")
            idle();compose.runOnIdle { model!!.signOut() };compose.waitUntil(30000) { model!!.state.value.snapshot?.userID==null && !model!!.state.value.busy };login(2)
            assertNull(snap().chat);assertTrue(snap().messaging!!.interactions.forwards.isEmpty())
            idle();compose.runOnIdle { model!!.signOut() };compose.waitUntil(30000) { model!!.state.value.snapshot?.userID==null && !model!!.state.value.busy }
            scenario!!.close();scenario=null;peerJob!!.cancelAndJoin();peerJob=null;peer.signOut();peer.close()
            assertEquals(0,SharedClient.activeClientCount());assertEquals(0,SharedClient.activeOperationCount());assertEquals(0,AndroidRuntimePlatform.install(context).activeHttpCount);assertEquals(0,AndroidRuntimePlatform.install(context).activeConnectionCount)
            File(context.filesDir,"shared-sdk-evidence.json").writeText(evidence.put("passed",true).put("accountIsolation",true).put("leakedClients",0).put("leakedOperations",0).put("leakedHTTP",0).put("leakedTLS",0).toString(2))
        } finally { scenario?.close();peerJob?.cancelAndJoin();peer.close() }
    }
}
