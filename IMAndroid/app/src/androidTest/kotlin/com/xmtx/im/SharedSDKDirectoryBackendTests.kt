package com.xmtx.im

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

/** All social/group business is performed by Swift, including the independent peer. */
class SharedSDKDirectoryBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun contactsGroupsPermissionsAndAccountIsolation() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base = requireNotNull(args.getString("sharedURL"))
        val port = requireNotNull(args.getString("sharedTLSPort")).toInt()
        val peerPort = requireNotNull(args.getString("sharedPeerTLSPort")).toInt()
        val control = requireNotNull(args.getString("sharedControlPort")).toInt()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(10)
        val password = UUID.randomUUID().toString() + "aA1!"
        val names = listOf("phase6_${run}_a", "phase6_${run}_b", "phase6_${run}_c")
        val accounts = names.map { SharedBackendFixture(base).register(it, password) }
        val a = accounts[0]; val b = accounts[1]; val c = accounts[2]
        val peer = SharedClient.open(context, SharedEndpoint(base, "localhost", peerPort))
        var peerJob: Job? = null
        var scenario: ActivityScenario<MainActivity>? = null
        var model: SharedAppViewModel? = null
        val evidence = JSONObject().put("realBackend", true).put("appEntry", "MainActivity").put("phase", 6)
        fun snap() = requireNotNull(model!!.state.value.snapshot)
        fun directory() = requireNotNull(snap().directory)
        fun idle() = compose.waitUntil(20000) { !model!!.state.value.busy }
        fun click(tag: String, list: String? = null) {
            idle()
            if (list != null) compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
            compose.onNodeWithTag(tag).performClick()
        }
        fun confirm() = click("shared_confirm")
        fun appWork(kind: String, previous: Set<String>, expected: String = "committed"): SharedWork {
            compose.waitUntil(60000) { directory().works.any { it.kind == kind && it.id !in previous && it.status in listOf("committed", "rejected", "conflicted", "closed", "expiredUnsubmitted", "paused") } }
            return directory().works.first { it.kind == kind && it.id !in previous }.also { assertEquals("App $kind: ${it.status}", expected, it.status) }
        }
        fun ids() = directory().works.map { it.id }.toSet()
        suspend fun peerWork(kind: String, previous: Set<String>, expected: String = "committed"): SharedWork = withTimeout(60000) {
            while (true) {
                peer.snapshot().directory!!.works.firstOrNull { it.kind == kind && it.id !in previous && it.status in listOf("committed", "rejected", "conflicted", "closed", "expiredUnsubmitted", "paused") }?.let {
                    assertEquals("Peer $kind: ${it.status}", expected, it.status); return@withTimeout it
                }
                delay(200)
            }
            @Suppress("UNREACHABLE_CODE") error("unreachable")
        }
        fun refreshGroup() {
            click("shared_group_refresh", "shared_group_detail"); idle()
            assertNotNull(directory().group)
        }
        fun relay(command: String) = Socket("localhost", control).use {
            it.soTimeout = 5000; it.outputStream.write((command + "\n").toByteArray()); assertEquals("OK", it.inputStream.bufferedReader().readLine())
        }
        try {
            peer.login(names[1], password)
            peerJob = launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(45000) { while (peer.snapshot().state != SharedSessionState.Connected) delay(200) }
            peer.socialAction(a.userID, SharedSocialAction.Request)
            peerWork("relationship", emptySet())
            SharedAppSettings.save(context, SharedEndpoint(base, "localhost", port))
            scenario = ActivityScenario.launch(MainActivity::class.java)
            scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }
            compose.waitUntil(20000) { model != null && !model!!.state.value.busy }
            compose.onNodeWithTag("shared_account").performTextInput(names[0])
            compose.onNodeWithTag("shared_password").performTextInput(password)
            click("shared_login")
            compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            compose.onNodeWithText("联系人").performClick()
            click("shared_contacts_incoming", "shared_contacts")
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            var before = ids()
            click("shared_accept_${b.userID}", "shared_contacts"); confirm(); appWork("relationship", before)
            click("shared_contacts_accepted", "shared_contacts")
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            peer.contacts(SharedContactScope.Accepted)
            withTimeout(30000) { while (peer.snapshot().directory!!.contacts.none { it.userID == a.userID }) delay(200) }
            evidence.put("requestAcceptTwoPeers", true)
            // Exact public-handle discovery, then the durable direct-room service.
            compose.onNodeWithTag("shared_contacts").performScrollToNode(hasTestTag("shared_lookup_handle"))
            compose.onNodeWithTag("shared_lookup_handle").performTextReplacement(names[1])
            click("shared_lookup", "shared_contacts")
            compose.waitUntil(20000) { directory().identity?.userID == b.userID }
            before = ids(); click("shared_direct", "shared_contacts")
            val direct = appWork("directRoom", before).roomID!!
            evidence.put("directRoom", direct)
            // UI group creation with a selected accepted contact.
            click("shared_groups", "shared_contacts")
            click("shared_new_group", "shared_group_directory")
            compose.onNodeWithTag("shared_group_title").performTextInput("共享群 $run")
            click("shared_select_${b.userID}", "shared_group_directory")
            before = ids(); click("shared_create_group", "shared_group_directory"); confirm()
            val room = appWork("groupRoom", before).roomID!!
            compose.waitUntil(45000) { directory().groups.any { it.id == room } }
            click("shared_group_$room", "shared_group_directory")
            compose.waitUntil(30000) { directory().group?.roomID == room && directory().group?.policiesReady == true }
            assertEquals(SharedRole.Owner, directory().group!!.actorRole)
            withTimeout(45000) {
                while (true) {
                    try { peer.openGroup(room); break } catch (error: SharedSdkException) {
                        if (error.reason != SharedError.InvalidInput) throw error; delay(250)
                    }
                }
            }
            var peerBefore = peer.snapshot().directory!!.works.map { it.id }.toSet()
            peer.groupAction(room, SharedGroupAction.Announcement, 0, text = "未经授权的公告")
            val denied = peerWork("groupAnnouncement", peerBefore, "paused")
            peer.discardDirectoryDraft(denied.id)
            evidence.put("memberAnnouncementDenied", true)
            compose.onNodeWithTag("shared_group_detail").performScrollToNode(hasTestTag("shared_announcement_input"))
            compose.onNodeWithTag("shared_announcement_input").performTextReplacement("真实群公告 $run")
            before = ids(); click("shared_save_announcement", "shared_group_detail"); confirm(); appWork("groupAnnouncement", before)
            withTimeout(30000) { while (peer.snapshot().directory!!.group?.announcement != "真实群公告 $run") delay(200) }
            before = ids(); click("shared_role_${b.userID}", "shared_group_detail"); confirm(); appWork("groupRole", before)
            // The displayed member revision is deliberately stale after role change: no auto-rebase.
            compose.onNodeWithTag("shared_group_detail").performScrollToNode(hasTestTag("shared_member_id"))
            compose.onNodeWithTag("shared_member_id").performTextReplacement(c.userID)
            before = ids(); click("shared_add_member", "shared_group_detail"); confirm(); val stale = appWork("membership", before, "paused")
            click("shared_discard_${stale.id}", "shared_group_detail")
            evidence.put("staleMembershipRevisionRejected", true)
            refreshGroup()
            before = ids(); click("shared_add_member", "shared_group_detail"); confirm(); appWork("membership", before)
            refreshGroup(); assertTrue(directory().group!!.members.any { it.userID == c.userID })
            before = ids(); click("shared_remove_${c.userID}", "shared_group_detail"); confirm(); appWork("membership", before)
            refreshGroup(); assertFalse(directory().group!!.members.any { it.userID == c.userID })
            before = ids()
            click("shared_permission_member_invite_members", "shared_group_detail")
            click("shared_save_permissions_member", "shared_group_detail"); confirm(); appWork("groupPermission", before)
            withTimeout(30000) { while (peer.snapshot().directory!!.group?.policies?.first { it.role == SharedRole.Member }?.permissions?.contains(SharedPermission.InviteMembers) != true) delay(200) }
            evidence.put("createAddRemoveRoleAnnouncementPermissions", true)
            // Break only the App TLS transport; it must recover group state from the shared runtime.
            relay("pause")
            compose.waitUntil(20000) { snap().state != SharedSessionState.Connected }
            relay("resume")
            compose.waitUntil(60000) { snap().state == SharedSessionState.Connected }
            refreshGroup()
            before = ids(); click("shared_transfer_${b.userID}", "shared_group_detail"); confirm(); appWork("groupOwnership", before)
            refreshGroup(); assertNotEquals(SharedRole.Owner, directory().group!!.actorRole)
            before = ids(); click("shared_leave_group", "shared_group_detail"); confirm(); appWork("membership", before)
            compose.waitUntil(45000) { directory().groups.none { it.id == room } && directory().group == null }
            peer.openGroup(room)
            assertEquals(SharedRole.Owner, peer.snapshot().directory!!.group!!.actorRole)
            peerBefore = peer.snapshot().directory!!.works.map { it.id }.toSet()
            peer.groupAction(room, SharedGroupAction.Dissolve, peer.snapshot().directory!!.group!!.revision)
            peerWork("groupDissolution", peerBefore)
            withTimeout(45000) { while (peer.snapshot().directory!!.groups.any { it.id == room }) delay(200) }
            evidence.put("transferLeaveDissolve", true).put("reconnected", true).put("groupRoom", room)
            // Full owner disposal then restore: contacts persist; expired discovery and group selection do not.
            scenario!!.close(); scenario = null
            withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            scenario = ActivityScenario.launch(MainActivity::class.java)
            scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }
            compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            assertNull(directory().identity); assertNull(directory().group)
            compose.onNodeWithText("联系人").performClick()
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            // Remove + block/unblock through the shared API; UI entry and receipt projection are already exercised.
            before = ids(); compose.runOnIdle { model!!.socialAction(b.userID, SharedSocialAction.Remove) }; appWork("relationship", before)
            before = ids(); compose.runOnIdle { model!!.socialAction(b.userID, SharedSocialAction.Block) }; appWork("userBlock", before)
            click("shared_contacts_blocked", "shared_contacts")
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            before = ids(); compose.runOnIdle { model!!.socialAction(b.userID, SharedSocialAction.Unblock) }; appWork("userBlock", before)
            compose.waitUntil(30000) { directory().contacts.isEmpty() }
            // Exercise both directions of rejection after removal; each click is a fresh domain command.
            compose.onNodeWithTag("shared_contacts").performScrollToNode(hasTestTag("shared_lookup_handle"))
            compose.onNodeWithTag("shared_lookup_handle").performTextReplacement(names[1])
            click("shared_lookup", "shared_contacts")
            compose.waitUntil(20000) { directory().identity?.userID == b.userID }
            before = ids(); click("shared_request", "shared_contacts"); confirm(); appWork("relationship", before)
            peerBefore = peer.snapshot().directory!!.works.map { it.id }.toSet()
            peer.socialAction(a.userID, SharedSocialAction.Reject); peerWork("relationship", peerBefore)
            peerBefore = peer.snapshot().directory!!.works.map { it.id }.toSet()
            peer.socialAction(a.userID, SharedSocialAction.Request); peerWork("relationship", peerBefore)
            click("shared_contacts_incoming", "shared_contacts")
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            before = ids(); click("shared_reject_${b.userID}", "shared_contacts"); confirm(); appWork("relationship", before)
            compose.waitUntil(30000) { directory().contacts.isEmpty() }
            evidence.put("appRequestAndReject", true)
            compose.onNodeWithText("我的").performClick(); click("shared_sign_out")
            compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            assertNull(model!!.state.value.snapshot?.directory)
            compose.onNodeWithTag("shared_account").performTextReplacement(names[2])
            compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login")
            compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            assertTrue(directory().contacts.isEmpty()); assertTrue(directory().works.isEmpty()); assertNull(directory().identity)
            evidence.put("contactsPersistedAndAccountIsolated", true).put("removeBlockUnblock", true)
            compose.onNodeWithText("我的").performClick(); click("shared_sign_out")
            compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            scenario!!.close(); scenario = null
            peerJob!!.cancelAndJoin(); peerJob = null; peer.signOut(); peer.close()
            withTimeout(20000) { while (SharedClient.activeClientCount() != 0) delay(20) }
            assertEquals(0, SharedClient.activeOperationCount())
            assertEquals(0, AndroidRuntimePlatform.install(context).activeConnectionCount)
            assertEquals(0, AndroidRuntimePlatform.install(context).activeHttpCount)
            File(context.filesDir, "shared-sdk-evidence.json").writeText(evidence.put("passed", true).put("leakedClients", 0).put("leakedOperations", 0).toString(2))
        } finally { scenario?.close(); peerJob?.cancelAndJoin(); peer.close() }
    }
}
