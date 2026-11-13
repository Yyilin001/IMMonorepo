package com.xmtx.im

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeEncoder
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

class SharedSDKAvatarBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun avatarEditingGroupAvatarAndScannedInvitation() = runBlocking<Unit> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base = requireNotNull(args.getString("sharedURL")); val port = args.getString("sharedTLSPort")!!.toInt()
        val peerPort = args.getString("sharedPeerTLSPort")!!.toInt(); val control = args.getString("sharedControlPort")!!.toInt()
        val context = instrumentation.targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(10)
        val password = UUID.randomUUID().toString() + "aA1!"
        val names = listOf("phase8_${run}_a", "phase8_${run}_b", "phase8_${run}_c")
        val fixture = SharedBackendFixture(base); val accounts = names.map { fixture.register(it, password) }
        val a = accounts[0]; val b = accounts[1]; val c = accounts[2]
        val peer = SharedClient.open(context, SharedEndpoint(base, "localhost", peerPort))
        var peerJob: Job? = null; var scenario: ActivityScenario<MainActivity>? = null; var model: SharedAppViewModel? = null
        val evidence = JSONObject().put("phase", 8).put("realBackend", true).put("appEntry", "MainActivity")
        fun directory() = model!!.state.value.snapshot!!.directory!!
        fun idle() = compose.waitUntil(30000) { !model!!.state.value.busy }
        fun click(tag: String, list: String? = null) {
            idle(); if (list != null) compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
            compose.waitUntil(20000) { compose.onAllNodes(hasTestTag(tag) and isEnabled()).fetchSemanticsNodes().size == 1 }
            compose.onNodeWithTag(tag).performClick()
        }
        fun ids() = directory().works.map { it.id }.toSet()
        fun appWork(kind: String, before: Set<String>): SharedWork {
            compose.waitUntil(60000) { directory().works.any { it.kind == kind && it.id !in before && it.status == "committed" } }
            return directory().works.first { it.kind == kind && it.id !in before }
        }
        suspend fun peerWork(kind: String, before: Set<String>): SharedWork = withTimeout(60000) {
            while (true) { peer.snapshot().directory!!.works.firstOrNull { it.kind == kind && it.id !in before && it.status == "committed" }?.let { return@withTimeout it }; delay(200) }
            @Suppress("UNREACHABLE_CODE") error("unreachable")
        }
        suspend fun peerIDs() = peer.snapshot().directory!!.works.map { it.id }.toSet()
        fun launchApp() { scenario = ActivityScenario.launch(MainActivity::class.java); scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }; idle() }
        fun imageFile(name: String, bitmap: Bitmap): Uri {
            val file = File(context.cacheDir, name); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle(); return Uri.fromFile(file)
        }
        val photo = Bitmap.createBitmap(800, 600, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.BLUE); android.graphics.Canvas(this).drawRect(200f, 100f, 650f, 550f, android.graphics.Paint().apply { color = Color.RED })
        }
        val photoURI = imageFile("phase8-photo.png", photo)
        fun choose(tag: String, list: String, uri: Uri) {
            val monitor = instrumentation.addMonitor(IntentFilter(Intent.ACTION_GET_CONTENT).apply { addDataType("image/*"); addCategory(Intent.CATEGORY_OPENABLE) }, Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(uri)), true)
            try { click(tag, list); compose.waitUntil(20000) { monitor.hits > 0 } } finally { instrumentation.removeMonitor(monitor) }
        }
        fun avatarReady() { compose.waitUntil(30000) { directory().avatarEditor != null && !model!!.state.value.busy } }
        fun avatarCommitted(previous: Set<String>) {
            compose.waitUntil(60000) { model!!.state.value.error != null || directory().avatarEditor?.works?.any { it.id !in previous && it.status in listOf("committed", "needsDecision", "closed", "needsAttention") } == true }
            assertNull("avatar command failed", model!!.state.value.error)
            assertEquals("avatar receipt", "committed", directory().avatarEditor!!.works.first { it.id !in previous }.status)
        }
        fun avatarIDs() = directory().avatarEditor!!.works.map { it.id }.toSet()
        fun upload() {
            choose("shared_avatar_pick", "shared_avatar_editor", photoURI)
            compose.waitUntil(20000) { compose.onAllNodesWithTag("shared_avatar_crop_preview").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("shared_avatar_editor").performScrollToNode(hasTestTag("shared_crop_zoom"))
            compose.onNodeWithTag("shared_crop_zoom").performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
            click("shared_avatar_crop", "shared_avatar_editor")
            val before = avatarIDs(); click("shared_avatar_upload", "shared_avatar_editor"); click("shared_confirm"); avatarCommitted(before)
        }
        try {
            peer.login(names[1], password); peerJob = launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(45000) { while (peer.snapshot().state != SharedSessionState.Connected) delay(200) }
            peer.socialAction(a.userID, SharedSocialAction.Request); peerWork("relationship", emptySet())
            SharedAppSettings.save(context, SharedEndpoint(base, "localhost", port)); launchApp()
            compose.onNodeWithTag("shared_account").performTextInput(names[0]); compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login")
            compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            var before = ids(); compose.runOnIdle { model!!.socialAction(b.userID, SharedSocialAction.Accept) }; appWork("relationship", before)
            compose.onNode(hasText("我的") and hasClickAction()).performClick(); click("shared_own_avatar"); avatarReady()
            upload(); click("shared_avatar_refresh", "shared_avatar_editor"); avatarReady()
            compose.waitUntil(30000) { directory().avatarEditor?.image != null }
            val ownRevision = directory().avatarEditor!!.revision
            peer.openProfile(a.userID); assertNotNull(peer.snapshot().directory!!.profiles.first().avatar)
            evidence.put("ownCropUploadPeerRead", true).put("ownAvatarRevision", ownRevision)
            val previous = avatarIDs(); click("shared_avatar_remove", "shared_avatar_editor"); click("shared_confirm"); avatarCommitted(previous)
            click("shared_avatar_refresh", "shared_avatar_editor"); avatarReady(); assertFalse(directory().avatarEditor!!.hasAvatar)
            peer.openProfile(a.userID); assertNull(peer.snapshot().directory!!.profiles.first().avatar)
            evidence.put("ownAvatarRemoved", true)
            compose.onNodeWithTag("shared_avatar_editor").performScrollToNode(hasText("返回")); compose.onNodeWithText("返回").performClick()
            before = ids(); compose.runOnIdle { model!!.createGroup("头像群 $run", listOf(b.userID)) }; val room = appWork("groupRoom", before).roomID!!
            compose.onNode(hasText("联系人") and hasClickAction()).performClick(); click("shared_groups", "shared_contacts")
            compose.waitUntil(45000) { directory().groups.any { it.id == room } }; click("shared_group_$room", "shared_group_directory")
            click("shared_group_avatar", "shared_group_detail"); avatarReady(); upload()
            click("shared_avatar_refresh", "shared_avatar_editor"); avatarReady(); compose.waitUntil(30000) { directory().avatarEditor?.image != null }
            val groupRevision = directory().avatarEditor!!.revision
            withTimeout(45000) { while (peer.snapshot().directory!!.groups.none { it.id == room }) delay(200) }
            peer.openAvatarEditor(room); val peerAvatar = peer.snapshot().directory!!.avatarEditor!!
            assertFalse(peerAvatar.canManage); assertNotNull(peerAvatar.image); assertTrue(runCatching { peer.changeAvatar(room, peerAvatar.revision) }.isFailure)
            evidence.put("groupUploadPeerReadAndMemberDenied", true).put("groupRoom", room).put("groupAvatarRevision", groupRevision)
            scenario!!.close(); scenario = null; withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            launchApp(); compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }; assertNull(directory().avatarEditor)
            compose.onNode(hasText("联系人") and hasClickAction()).performClick(); click("shared_groups", "shared_contacts"); click("shared_group_$room", "shared_group_directory"); click("shared_group_avatar", "shared_group_detail"); avatarReady()
            compose.waitUntil(30000) { directory().avatarEditor?.image != null }; assertEquals(groupRevision, directory().avatarEditor!!.revision)
            evidence.put("ownerReopenAvatarPersisted", true)
            val beforeRemove = avatarIDs(); click("shared_avatar_remove", "shared_avatar_editor"); click("shared_confirm"); avatarCommitted(beforeRemove)
            click("shared_avatar_refresh", "shared_avatar_editor"); avatarReady(); assertFalse(directory().avatarEditor!!.hasAvatar)
            peer.openAvatarEditor(room); assertNull(peer.snapshot().directory!!.avatarEditor!!.image)
            evidence.put("groupAvatarRemoved", true)
            scenario!!.close(); scenario = null; withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }; launchApp(); compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            var peerBefore = peerIDs(); peer.createGroup("扫码邀请群 $run", listOf(c.userID)); val joinRoom = peerWork("groupRoom", peerBefore).roomID!!
            withTimeout(45000) { while (true) { try { peer.openGroup(joinRoom); break } catch (e: SharedSdkException) { if (e.reason != SharedError.InvalidInput) throw e; delay(200) } } }
            peer.invitations(joinRoom); peerBefore = peerIDs(); peer.inviteAction(joinRoom, SharedInviteAction.Create, peer.snapshot().directory!!.group!!.revision); peerWork("groupInvite", peerBefore)
            val link = peer.invitations(joinRoom).directory!!.community!!.invites.single()
            val qr = imageFile("phase8-invite.png", BarcodeEncoder().encodeBitmap(link.url, BarcodeFormat.QR_CODE, 512, 512))
            compose.onNode(hasText("联系人") and hasClickAction()).performClick(); click("shared_join_entry", "shared_contacts")
            choose("shared_scan_image", "shared_join", qr)
            compose.waitUntil(30000) { directory().community?.preview?.roomID == joinRoom }
            before = ids(); click("shared_join_submit", "shared_join"); click("shared_confirm"); appWork("groupJoinRequest", before)
            val request = peer.invitations(joinRoom).directory!!.community!!.requests.single { it.userID == a.userID }
            peerBefore = peerIDs(); peer.inviteAction(joinRoom, SharedInviteAction.Approve, peer.snapshot().directory!!.group!!.revision, request.id); peerWork("groupJoinDecision", peerBefore)
            compose.waitUntil(45000) { directory().groups.any { it.id == joinRoom } }
            evidence.put("qrImageDecodedAndRealJoinApproved", true)
            val invalidQR = imageFile("phase8-invalid.png", BarcodeEncoder().encodeBitmap("https://invalid.example/not-an-invitation", BarcodeFormat.QR_CODE, 512, 512))
            choose("shared_scan_image", "shared_join", invalidQR)
            compose.waitUntil(30000) { directory().community?.preview == null && model!!.state.value.error != null }
            evidence.put("nonInviteQRRejectedBySwift", true)
            instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.CAMERA").close()
            val cameraMonitor = instrumentation.addMonitor("com.journeyapps.barcodescanner.CaptureActivity", null, false)
            try {
                click("shared_scan_camera", "shared_join")
                val camera = instrumentation.waitForMonitorWithTimeout(cameraMonitor, 15000)
                assertNotNull("camera scanner activity", camera)
                instrumentation.runOnMainSync { camera.finish() }
            } finally { instrumentation.removeMonitor(cameraMonitor) }
            compose.waitForIdle(); evidence.put("cameraScannerOpenCancel", true)
            Socket("localhost", control).use { it.soTimeout = 5000; it.outputStream.write("pause\n".toByteArray()); assertEquals("OK", it.inputStream.bufferedReader().readLine()) }
            compose.waitUntil(20000) { model!!.state.value.snapshot?.state != SharedSessionState.Connected }
            Socket("localhost", control).use { it.soTimeout = 5000; it.outputStream.write("resume\n".toByteArray()); assertEquals("OK", it.inputStream.bufferedReader().readLine()) }
            compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }; evidence.put("reconnected", true)
            compose.runOnIdle { model!!.signOut() }; compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            compose.onNodeWithTag("shared_account").performTextReplacement(names[2]); compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login")
            compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }; assertNull(directory().avatarEditor)
            compose.runOnIdle { model!!.signOut() }; compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            scenario!!.close(); scenario = null; peerJob!!.cancelAndJoin(); peerJob = null; peer.signOut(); peer.close()
            withTimeout(20000) { while (SharedClient.activeClientCount() != 0) delay(20) }
            // The Android path fix must preserve rejection of substituted child directories.
            val resourceDirectories = File(context.noBackupFilesDir, "shared-sdk").walkTopDown().filter { it.isDirectory && it.name == "files" && it.parentFile?.name == "resources" }.toList()
            assertTrue(resourceDirectories.isNotEmpty())
            val outside = File(context.cacheDir, "phase8-outside").apply { mkdirs() }
            val canary = File(outside, "canary").apply { writeText("unchanged") }
            val replaced = mutableListOf<Pair<File, File>>()
            val unsafe = SharedClient.open(context, SharedEndpoint(base, "localhost", port))
            try {
                resourceDirectories.forEach { original ->
                    val saved = File(original.parentFile, "files-phase8-saved"); check(original.renameTo(saved)); replaced += original to saved
                    android.system.Os.symlink(outside.absolutePath, original.absolutePath)
                }
                assertTrue(runCatching { unsafe.login(names[0], password) }.isFailure)
                assertEquals("unchanged", canary.readText())
            } finally {
                unsafe.close()
                replaced.forEach { (original, saved) -> java.nio.file.Files.delete(original.toPath()); check(saved.renameTo(original)) }
                outside.deleteRecursively()
            }
            val restored = SharedClient.open(context, SharedEndpoint(base, "localhost", port))
            try { assertEquals(a.userID, restored.restore().userID); restored.signOut() } finally { restored.close() }
            evidence.put("resourceChildSymlinkRejected", true)
            assertEquals(0, SharedClient.activeOperationCount()); assertEquals(0, AndroidRuntimePlatform.install(context).activeHttpCount); assertEquals(0, AndroidRuntimePlatform.install(context).activeConnectionCount)
            File(context.filesDir, "shared-sdk-evidence.json").writeText(evidence.put("passed", true).put("accountIsolation", true).put("leakedClients", 0).put("leakedOperations", 0).toString(2))
        } finally { scenario?.close(); peerJob?.cancelAndJoin(); peer.close(); listOf("phase8-photo.png", "phase8-invite.png", "phase8-invalid.png").forEach { File(context.cacheDir, it).delete() } }
    }
}
