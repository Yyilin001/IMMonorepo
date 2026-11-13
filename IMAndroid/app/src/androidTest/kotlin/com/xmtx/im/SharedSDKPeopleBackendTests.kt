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

class SharedSDKPeopleBackendTests {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun authorizedProfilesAliasesAvatarsInvitationsAndMute() = runBlocking<Unit> {
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(args.getString("sharedURL") != null)
        val base = requireNotNull(args.getString("sharedURL"))
        val port = requireNotNull(args.getString("sharedTLSPort")).toInt()
        val peerPort = requireNotNull(args.getString("sharedPeerTLSPort")).toInt()
        val control = requireNotNull(args.getString("sharedControlPort")).toInt()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val run = UUID.randomUUID().toString().replace("-", "").take(10)
        val password = UUID.randomUUID().toString() + "aA1!"
        val names = listOf("phase7_${run}_a", "phase7_${run}_b", "phase7_${run}_c")
        val fixture = SharedBackendFixture(base)
        val accounts = names.map { fixture.register(it, password) }
        val a = accounts[0]; val b = accounts[1]; val c = accounts[2]
        fixture.avatar(b, android.graphics.Color.BLUE)
        val peer = SharedClient.open(context, SharedEndpoint(base, "localhost", peerPort))
        var peerJob: Job? = null
        var scenario: ActivityScenario<MainActivity>? = null
        var model: SharedAppViewModel? = null
        val evidence = JSONObject().put("phase", 7).put("realBackend", true).put("appEntry", "MainActivity")
        fun directory() = model!!.state.value.snapshot!!.directory!!
        fun idle() = compose.waitUntil(20000) { !model!!.state.value.busy }
        fun click(tag: String, list: String? = null) {
            idle()
            if (list != null) compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag))
            compose.waitUntil(20000) { compose.onAllNodes(hasTestTag(tag) and isEnabled()).fetchSemanticsNodes().size == 1 }
            compose.onNodeWithTag(tag).performClick()
        }
        fun ids() = directory().works.map { it.id }.toSet()
        fun appWork(kind: String, before: Set<String>, status: String = "committed"): SharedWork {
            compose.waitUntil(60000) { directory().works.any { it.kind == kind && it.id !in before && it.status in listOf("committed", "rejected", "conflicted", "paused") } }
            return directory().works.first { it.kind == kind && it.id !in before }.also { assertEquals("App $kind", status, it.status) }
        }
        suspend fun peerWork(kind: String, before: Set<String>, status: String = "committed"): SharedWork = withTimeout(60000) {
            while (true) {
                peer.snapshot().directory!!.works.firstOrNull { it.kind == kind && it.id !in before && it.status in listOf("committed", "rejected", "conflicted", "paused") }?.let { assertEquals("Peer $kind", status, it.status); return@withTimeout it }
                delay(200)
            }
            @Suppress("UNREACHABLE_CODE") error("unreachable")
        }
        suspend fun peerIDs() = peer.snapshot().directory!!.works.map { it.id }.toSet()
        fun relay(command: String) = Socket("localhost", control).use { it.soTimeout = 5000; it.outputStream.write((command + "\n").toByteArray()); assertEquals("OK", it.inputStream.bufferedReader().readLine()) }
        try {
            peer.login(names[1], password); peerJob = launch(Dispatchers.Default) { peer.foregroundStates().collect {} }
            withTimeout(45000) { while (peer.snapshot().state != SharedSessionState.Connected) delay(200) }
            peer.socialAction(a.userID, SharedSocialAction.Request); peerWork("relationship", emptySet())
            SharedAppSettings.save(context, SharedEndpoint(base, "localhost", port))
            fun launchApp() { scenario = ActivityScenario.launch(MainActivity::class.java); scenario!!.onActivity { model = ViewModelProvider(it)[SharedAppViewModel::class.java] }; compose.waitUntil(20000) { model != null && !model!!.state.value.busy } }
            launchApp()
            compose.onNodeWithTag("shared_account").performTextInput(names[0]); compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login")
            compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            var before = ids(); compose.runOnIdle { model!!.socialAction(b.userID, SharedSocialAction.Accept) }; appWork("relationship", before)
            compose.onNode(hasText("联系人") and hasClickAction()).performClick()
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            click("shared_profile_${b.userID}", "shared_contacts")
            compose.waitUntil(30000) { directory().profiles.any { it.userID == b.userID && it.avatar != null } }
            compose.onNodeWithTag("shared_profile_name").assertTextEquals(names[1]); compose.onNodeWithTag("shared_profile_avatar").assertIsDisplayed()
            val firstAvatar = directory().profiles.single().avatar!!
            compose.onNodeWithTag("shared_alias").performTextReplacement("我的联系人备注")
            before = ids(); click("shared_save_alias", "shared_profile_detail"); click("shared_confirm"); appWork("contactAlias", before)
            compose.waitUntil(30000) { directory().profiles.any { it.alias == "我的联系人备注" } }
            peer.openProfile(a.userID); assertNull(peer.snapshot().directory!!.profiles.firstOrNull()?.alias)
            fixture.avatar(b, android.graphics.Color.RED)
            click("shared_profile_refresh", "shared_profile_detail")
            compose.waitUntil(30000) { directory().profiles.any { it.avatar != null && it.avatar != firstAvatar } }
            evidence.put("authorizedProfileAndAvatarReplaced", true).put("aliasPrivateAndCommitted", true)
            // Expired grants cannot keep rendering pixels after the current foreground owner stops.
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            compose.waitUntil(20000) { directory().profiles.isEmpty() }
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            click("shared_profile_refresh", "shared_profile_detail")
            compose.waitUntil(30000) { directory().profiles.any { it.alias == "我的联系人备注" } }
            scenario!!.close(); scenario = null
            withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            launchApp(); compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            assertTrue(directory().profiles.isEmpty())
            compose.onNode(hasText("联系人") and hasClickAction()).performClick()
            compose.waitUntil(30000) { directory().contacts.any { it.userID == b.userID } }
            click("shared_profile_${b.userID}", "shared_contacts")
            compose.waitUntil(30000) { directory().profiles.any { it.alias == "我的联系人备注" } }
            // Unrelated user cannot be rendered by changing only the target ID.
            compose.runOnIdle { model!!.openProfile(c.userID) }; idle()
            assertTrue(directory().profiles.none { it.userID == c.userID })
            evidence.put("backgroundAndReopenClearGrants", true).put("unauthorizedProfileNotDisplayed", true)
            // Reset navigation while retaining the account, then create a group through Swift.
            scenario!!.close(); scenario = null; withTimeout(20000) { while (SharedClient.activeClientCount() != 1) delay(20) }
            launchApp(); compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            // Also exercise the Android applicant page, with the independent peer as group owner.
            var ownerBefore = peerIDs()
            peer.createGroup("对端邀请群 $run", listOf(c.userID))
            val peerRoom = peerWork("groupRoom", ownerBefore).roomID!!
            withTimeout(45000) { while (true) { try { peer.openGroup(peerRoom); break } catch (error: SharedSdkException) { if (error.reason != SharedError.InvalidInput) throw error; delay(200) } } }
            peer.invitations(peerRoom)
            ownerBefore = peerIDs(); peer.inviteAction(peerRoom, SharedInviteAction.Create, peer.snapshot().directory!!.group!!.revision); peerWork("groupInvite", ownerBefore)
            val peerLink = peer.invitations(peerRoom).directory!!.community!!.invites.single()
            compose.onNode(hasText("联系人") and hasClickAction()).performClick(); click("shared_join_entry", "shared_contacts")
            compose.onNodeWithTag("shared_invite_input").performTextInput(peerLink.url); click("shared_invite_preview", "shared_join")
            compose.waitUntil(20000) { directory().community?.preview?.roomID == peerRoom }
            before = ids(); click("shared_join_submit", "shared_join"); click("shared_confirm"); appWork("groupJoinRequest", before)
            val applicant = peer.invitations(peerRoom).directory!!.community!!.requests.first { it.userID == a.userID }
            ownerBefore = peerIDs(); peer.inviteAction(peerRoom, SharedInviteAction.Approve, peer.snapshot().directory!!.group!!.revision, applicant.id); peerWork("groupJoinDecision", ownerBefore)
            compose.waitUntil(45000) { directory().groups.any { it.id == peerRoom } }
            compose.onNodeWithTag("shared_join").performScrollToNode(hasText("返回")); compose.onNodeWithText("返回").performClick()
            evidence.put("androidApplicantPage", true)
            before = ids(); compose.runOnIdle { model!!.createGroup("邀请群 $run", listOf(c.userID)) }
            val room = appWork("groupRoom", before).roomID!!
            compose.onNode(hasText("联系人") and hasClickAction()).performClick(); click("shared_groups", "shared_contacts")
            compose.waitUntil(45000) { directory().groups.any { it.id == room } }
            click("shared_group_$room", "shared_group_directory")
            compose.waitUntil(30000) { directory().group?.policiesReady == true }
            click("shared_invitation_management", "shared_group_detail"); idle()
            before = ids(); click("shared_invite_create", "shared_invitations"); click("shared_confirm"); appWork("groupInvite", before)
            click("shared_invites_refresh", "shared_invitations")
            compose.waitUntil(20000) { directory().community?.invites?.isNotEmpty() == true }
            var invite = directory().community!!.invites.single()
            fun freshInvitation(): SharedInvite {
                val previous = directory().community!!.invites.map { it.id }.toSet()
                val oldWork = ids(); click("shared_invite_create", "shared_invitations"); click("shared_confirm"); appWork("groupInvite", oldWork)
                click("shared_invites_refresh", "shared_invitations")
                compose.waitUntil(20000) { directory().community!!.invites.any { it.id !in previous } }
                return directory().community!!.invites.first { it.id !in previous }
            }
            assertFalse(invite.toString().contains(invite.url))
            peer.previewInvite(invite.url)
            var peerBefore = peerIDs(); peer.inviteAction(room, SharedInviteAction.Submit, note = "真实申请"); peerWork("groupJoinRequest", peerBefore)
            peer.previewInvite(invite.url)
            assertNotNull(peer.snapshot().directory!!.community!!.preview!!.requestID)
            peerBefore = peerIDs(); peer.inviteAction(room, SharedInviteAction.Cancel); peerWork("groupJoinRequest", peerBefore)
            invite = freshInvitation()
            peer.previewInvite(invite.url)
            peerBefore = peerIDs(); peer.inviteAction(room, SharedInviteAction.Submit, note = "重新申请"); peerWork("groupJoinRequest", peerBefore)
            click("shared_invites_refresh", "shared_invitations")
            compose.waitUntil(20000) { directory().community?.requests?.any { it.userID == b.userID && it.state == "pending" } == true }
            var request = directory().community!!.requests.first { it.userID == b.userID && it.state == "pending" }
            before = ids(); click("shared_join_reject_${request.id}", "shared_invitations"); click("shared_confirm"); appWork("groupJoinDecision", before)
            invite = freshInvitation()
            peer.previewInvite(invite.url); peerBefore = peerIDs(); peer.inviteAction(room, SharedInviteAction.Submit); peerWork("groupJoinRequest", peerBefore)
            click("shared_invites_refresh", "shared_invitations")
            compose.waitUntil(20000) { directory().community?.requests?.any { it.userID == b.userID && it.state == "pending" } == true }
            request = directory().community!!.requests.first { it.userID == b.userID && it.state == "pending" }
            before = ids(); click("shared_join_approve_${request.id}", "shared_invitations"); click("shared_confirm"); appWork("groupJoinDecision", before)
            withTimeout(45000) { while (peer.snapshot().directory!!.groups.none { it.id == room }) delay(200) }
            withTimeout(30000) { while (true) { try { peer.openGroup(room); break } catch (error: SharedSdkException) { if (error.reason != SharedError.InvalidInput) throw error; delay(200) } } }
            evidence.put("inviteCreateCancelRejectApprove", true)
            compose.onNodeWithTag("shared_invitations").performScrollToNode(hasText("返回")); compose.onNodeWithText("返回").performClick()
            click("shared_group_refresh", "shared_group_detail"); idle()
            peerBefore = peerIDs(); peer.muteMember(room, a.userID, peer.snapshot().directory!!.group!!.revision)
            val denied = peerWork("memberMute", peerBefore, "paused"); peer.discardDirectoryDraft(denied.id)
            before = ids(); click("shared_mute_${b.userID}", "shared_group_detail"); click("shared_confirm"); appWork("memberMute", before)
            peer.openConversation(room)
            val deniedText = "禁言不应发出 $run"; peer.sendText(room, deniedText)
            withTimeout(30000) { while (peer.snapshot().chat!!.pending.none { it.text == deniedText && it.status == SharedSendStatus.Rejected }) delay(200) }
            assertTrue(peer.snapshot().chat!!.messages.none { it.text == deniedText })
            evidence.put("memberCannotMuteOwner", true).put("mutedSendRejected", true).put("groupRoom", room)
            relay("pause"); compose.waitUntil(20000) { model!!.state.value.snapshot?.state != SharedSessionState.Connected }; relay("resume")
            compose.waitUntil(60000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            click("shared_group_refresh", "shared_group_detail")
            click("shared_invitation_management", "shared_group_detail"); idle()
            before = ids(); click("shared_invite_revoke_${invite.id}", "shared_invitations"); click("shared_confirm"); appWork("groupInvite", before)
            assertTrue(runCatching { peer.previewInvite(invite.url) }.isFailure)
            assertNull(peer.snapshot().directory!!.community?.preview)
            evidence.put("revokedInviteClearsPreview", true).put("reconnected", true)
            // Sign out wipes profile grants, avatar bytes and invite bearers from UI state.
            compose.runOnIdle { model!!.signOut() }
            compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            assertNull(model!!.state.value.snapshot?.directory)
            compose.onNodeWithTag("shared_account").performTextReplacement(names[2]); compose.onNodeWithTag("shared_password").performTextInput(password); click("shared_login")
            compose.waitUntil(45000) { model!!.state.value.snapshot?.state == SharedSessionState.Connected }
            assertTrue(directory().profiles.isEmpty()); assertTrue(directory().community!!.invites.isEmpty()); assertNull(directory().community!!.preview)
            evidence.put("accountIsolation", true)
            compose.runOnIdle { model!!.signOut() }; compose.waitUntil(20000) { !model!!.state.value.busy && model!!.state.value.snapshot?.userID == null }
            scenario!!.close(); scenario = null; peerJob!!.cancelAndJoin(); peerJob = null; peer.signOut(); peer.close()
            withTimeout(20000) { while (SharedClient.activeClientCount() != 0) delay(20) }
            assertEquals(0, SharedClient.activeOperationCount()); assertEquals(0, AndroidRuntimePlatform.install(context).activeHttpCount); assertEquals(0, AndroidRuntimePlatform.install(context).activeConnectionCount)
            File(context.filesDir, "shared-sdk-evidence.json").writeText(evidence.put("passed", true).put("leakedClients", 0).put("leakedOperations", 0).toString(2))
        } finally { scenario?.close(); peerJob?.cancelAndJoin(); peer.close() }
    }
}
