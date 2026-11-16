package com.xmtx.im

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
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
import java.io.*
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID

class SharedSDKMediaBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun imageAndFileMessagesUseSharedResourceRuntime() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base = args.getString("sharedURL")!!; val port = args.getString("sharedTLSPort")!!.toInt()
        val peerPort = args.getString("sharedPeerTLSPort")!!.toInt(); val control = args.getString("sharedControlPort")!!.toInt()
        val context = instrumentation.targetContext; val run = UUID.randomUUID().toString().replace("-", "").take(10)
        val names = listOf("phase9_${run}_a", "phase9_${run}_b", "phase9_${run}_c"); val password = UUID.randomUUID().toString() + "aA1!"
        val fixture = SharedBackendFixture(base); val accounts = names.map { fixture.register(it, password) }; val room = fixture.direct(accounts[1], accounts[0])
        val peer = SharedClient.open(context, SharedEndpoint(base,"localhost",peerPort)); var peerJob: Job? = null
        var scenario: ActivityScenario<MainActivity>? = null; var model: SharedAppViewModel? = null
        val evidence = JSONObject().put("phase",9).put("realBackend",true).put("roomID",room).put("appEntry","MainActivity")
        val bytes = ByteArray(9 * 1024 * 1024) { (65 + it % 26).toByte() }
        val outgoingBytes = ByteArray(bytes.size) { (97 + it % 26).toByte() }
        val source = File(context.cacheDir,"phase9-source.txt").apply { writeBytes(outgoingBytes) }
        val output = File(context.cacheDir,"phase9-export.txt")
        val photo = File(context.cacheDir,"phase9-photo.png")
        val bitmap = Bitmap.createBitmap(640,480,Bitmap.Config.ARGB_8888).apply { eraseColor(Color.CYAN) }
        photo.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) }; bitmap.recycle()
        fun hash(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        fun idle() { compose.waitUntil(60000) { model != null && !model!!.state.value.busy } }
        fun click(tag: String, list: String? = null) {
            idle(); if (list != null) compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
            compose.onNodeWithTag(tag).performClick()
        }
        fun launchApp() { scenario = ActivityScenario.launch(MainActivity::class.java); scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }; idle() }
        fun login(index: Int) { compose.onNodeWithTag("shared_account").performTextReplacement(names[index]); compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login"); compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected } }
        fun openChat() { compose.waitUntil(45000) { model!!.state.value.snapshot?.conversations?.any { it.id == room } == true }; click("shared_room_$room","shared_conversations"); compose.waitUntil(30000) { model!!.state.value.snapshot?.chat?.roomID == room } }
        fun shell(command: String) = android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
        fun restoreNetworkPolicy() { shell("cmd netpolicy set restrict-background false"); shell("cmd netpolicy set metered-network AndroidWifi undefined") }
        fun relay(value: String) = Socket("localhost",control).use { it.soTimeout=5000; it.outputStream.write((value+"\n").toByteArray()); assertEquals("OK",it.inputStream.bufferedReader().readLine()) }
        fun select(tag: String, mime: String, file: File) {
            val monitor = instrumentation.addMonitor(IntentFilter(Intent.ACTION_GET_CONTENT).apply { addDataType(mime); addCategory(Intent.CATEGORY_OPENABLE) }, Instrumentation.ActivityResult(Activity.RESULT_OK,Intent().setData(Uri.fromFile(file))),true)
            try { click(tag); compose.waitUntil(15000) { monitor.hits>0 } } finally { instrumentation.removeMonitor(monitor) }
            compose.waitUntil(60000) { !model!!.state.value.busy && (model!!.state.value.snapshot?.resource?.draft != null || model!!.state.value.error != null) }; assertNull(model!!.state.value.error)
        }
        suspend fun peerMessage(text: String): SharedMessage = withTimeout(120000) {
            while (true) { peer.snapshot().chat?.messages?.firstOrNull { it.text == text && it.attachments.isNotEmpty() }?.let { return@withTimeout it }; delay(200) }; error("unreachable")
        }
        suspend fun sendPeer(data: ByteArray, name: String, type: String, text: String, width: Int? = null, height: Int? = null): SharedMessage {
            val draft = peer.importAttachment(room,name,type,ByteArrayInputStream(data),width,height).resource!!.draft!!
            peer.sendAttachment(room,draft.id,text); return peerMessage(text)
        }
        try {
            peer.login(names[1],password); peerJob=launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(60000) { while (true) { try { peer.openConversation(room); break } catch (_: SharedSdkException) { delay(200) } } }
            val incomingFile = sendPeer(bytes,"real-file.txt","text/plain","incoming file $run")
            val incomingImage = sendPeer(photo.readBytes(),"real-image.png","image/png","incoming image $run",640,480)
            evidence.put("incomingFileMediaID",incomingFile.attachments.single().id).put("incomingImageMediaID",incomingImage.attachments.single().id)
            SharedAppSettings.save(context,SharedEndpoint(base,"localhost",port)); launchApp(); login(0)
            compose.onNode(hasText("我的") and hasClickAction()).performClick()
            compose.onNodeWithTag("shared_own_avatar").assertExists()
            compose.onNodeWithTag("shared_all_transfers").assertDoesNotExist()
            compose.onNode(hasText("消息") and hasClickAction()).performClick()
            openChat()
            compose.waitUntil(60000) { model!!.state.value.snapshot?.chat?.messages?.any { it.id==incomingImage.id } == true }
            click("shared_attachment_${incomingImage.attachments.single().id}","shared_messages"); idle()
            shell("cmd netpolicy set metered-network AndroidWifi true"); shell("cmd netpolicy set restrict-background true")
            try {
                val network = context.getSystemService(android.net.ConnectivityManager::class.java)
                compose.waitUntil(10000) { network.isActiveNetworkMetered && network.restrictBackgroundStatus != android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED }
                click("shared_resource_preview","shared_resource_detail")
                compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.error != null }
                assertNull(model!!.state.value.snapshot?.resource?.image); evidence.put("dataSaverDownloadPolicyEnforced",true)
            } finally { restoreNetworkPolicy() }
            click("shared_resource_preview","shared_resource_detail")
            compose.waitUntil(45000) { model!!.state.value.snapshot?.resource?.image != null || model!!.state.value.error != null }; assertNull(model!!.state.value.error)
            compose.onNodeWithTag("shared_resource_image").assertExists(); evidence.put("incomingImagePreview",true)
            compose.onNodeWithText("返回").performClick()
            click("shared_attachment_${incomingFile.attachments.single().id}","shared_messages"); idle(); click("shared_resource_download","shared_resource_detail")
            compose.waitUntil(120000) { model!!.state.value.snapshot?.resource?.transfers?.any { it.kind=="download" && it.phase=="completed" && it.bytes==bytes.size.toLong() } == true }
            val save = instrumentation.addMonitor(IntentFilter(Intent.ACTION_CREATE_DOCUMENT).apply { addDataType("text/plain"); addCategory(Intent.CATEGORY_OPENABLE) },Instrumentation.ActivityResult(Activity.RESULT_OK,Intent().setData(Uri.fromFile(output))),true)
            try { click("shared_resource_save","shared_resource_detail"); compose.waitUntil(15000) { save.hits>0 } } finally { instrumentation.removeMonitor(save) }
            compose.waitUntil(60000) { compose.onAllNodesWithTag("shared_resource_saved").fetchSemanticsNodes().isNotEmpty() || model!!.state.value.error != null }; assertNull(model!!.state.value.error)
            assertEquals(hash(bytes),hash(output.readBytes())); evidence.put("fileDownloadAndDocumentExportSHA256",hash(bytes)).put("fileBytes",bytes.size)
            compose.onNodeWithTag("shared_resource_transfers").assertDoesNotExist()
            compose.onNodeWithText("返回").performClick()
            compose.onNodeWithTag("shared_chat_transfers").assertDoesNotExist()
            select("shared_attach_image","image/*",photo); compose.onNodeWithTag("shared_composer").performTextInput("outgoing image $run"); click("shared_send_attachment")
            val outgoingImage=peerMessage("outgoing image $run"); peer.openResource(room,outgoingImage.id,outgoingImage.attachments.single().id); assertNotNull(peer.previewResource().resource!!.image)
            assertEquals("image",outgoingImage.attachments.single().kind); evidence.put("appImageSelectionUploadAndPeerPreview",true).put("outgoingImageMediaID",outgoingImage.attachments.single().id)
            select("shared_attach_file","*/*",source); compose.onNodeWithTag("shared_composer").performTextInput("offline file $run")
            relay("pause"); compose.waitUntil(20000) { model!!.state.value.snapshot?.state != SharedSessionState.Connected }; click("shared_send_attachment")
            compose.waitUntil(30000) { model!!.state.value.snapshot?.chat?.pending?.any { it.text=="offline file $run" }==true }
            scenario!!.close(); scenario=null; withTimeout(30000) { while (SharedClient.activeClientCount()!=1) delay(50) }
            relay("resume"); launchApp(); compose.waitUntil(60000) { model!!.state.value.snapshot?.state==SharedSessionState.Connected }; openChat()
            val outgoingFile=peerMessage("offline file $run"); peer.openResource(room,outgoingFile.id,outgoingFile.attachments.single().id); peer.downloadResource()
            withTimeout(120000) { while (peer.snapshot().resource!!.transfers.none { it.kind=="download" && it.phase=="completed" && it.bytes==bytes.size.toLong() }) delay(200) }
            val received=ByteArrayOutputStream(); peer.exportResource(received); assertEquals(hash(outgoingBytes),hash(received.toByteArray()))
            assertEquals(1,peer.snapshot().chat!!.messages.count { it.text=="offline file $run" }); evidence.put("offlineSendOwnerReopenExactlyOnce",true).put("outgoingFileMediaID",outgoingFile.attachments.single().id).put("peerDownloadVerified",true).put("outgoingFileSHA256",hash(outgoingBytes))
            assertTrue(runCatching { peer.openResource(room,UUID.randomUUID().toString(),incomingFile.attachments.single().id) }.isFailure); assertNull(peer.snapshot().resource!!.selected)
            val importReading = CompletableDeferred<Unit>()
            val importing=launch(Dispatchers.Default) { peer.importAttachment(room,"cancel.txt","text/plain",object: InputStream() { override fun read(): Int=65; override fun read(b:ByteArray,off:Int,len:Int):Int { importReading.complete(Unit); Thread.sleep(500); b.fill(65,off,off+len);return len } }) }
            withTimeout(10000) { importReading.await() }; importing.cancelAndJoin(); assertNull(peer.snapshot().resource!!.draft); assertNull(peer.snapshot().resource!!.importID)
            evidence.put("cancelledImportDrained",true).put("unrelatedMessageRejected",true)
            compose.runOnIdle { model!!.signOut() }; compose.waitUntil(30000) { model!!.state.value.snapshot?.userID==null && !model!!.state.value.busy }; login(2)
            assertNull(model!!.state.value.snapshot?.resource?.draft); assertNull(model!!.state.value.snapshot?.resource?.selected); assertTrue(model!!.state.value.snapshot!!.resource!!.transfers.isEmpty())
            compose.runOnIdle { model!!.signOut() }; compose.waitUntil(30000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID==null }
            scenario!!.close(); scenario=null; peerJob!!.cancelAndJoin(); peerJob=null; peer.signOut(); peer.close()
            assertTrue(File(context.noBackupFilesDir,"shared-sdk").walkTopDown().filter { it.isDirectory && it.name == "shared-imports" }.all { it.listFiles()?.isEmpty() == true })
            evidence.put("importStagingCleaned",true)
            assertEquals(0,SharedClient.activeClientCount()); assertEquals(0,SharedClient.activeOperationCount()); assertEquals(0,AndroidRuntimePlatform.install(context).activeHttpCount); assertEquals(0,AndroidRuntimePlatform.install(context).activeConnectionCount)
            File(context.filesDir,"shared-sdk-evidence.json").writeText(evidence.put("passed",true).put("accountIsolation",true).put("leakedClients",0).put("leakedOperations",0).toString(2))
        } finally { restoreNetworkPolicy(); scenario?.close(); peerJob?.cancelAndJoin(); peer.close(); listOf(source,output,photo).forEach { it.delete() } }
    }
}
