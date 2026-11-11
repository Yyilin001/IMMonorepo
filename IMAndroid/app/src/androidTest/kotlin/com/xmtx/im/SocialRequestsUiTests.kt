package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SocialRequestsUiTests {
    @get:Rule val compose = createComposeRule()
    private fun user(n: Int) = UserId("30000000-0000-0000-0000-${n.toString().padStart(12, '0')}")
    private val actor = user(999)
    @Test fun directionsHaveBoundedIndependentRestorableWindowsAndRetireReaders() {
        var rows = ((1..120).map { Relationship(user(it), RelationshipState.Pending, user(it), 1) } +
            (201..260).map { Relationship(user(it), RelationshipState.Pending, actor, 1) }).toPersistentList()
        val changes = MutableStateFlow(0L)
        val store = object: RelationshipWindowStore {
            private fun source() = DemoRelationshipPages(persistentListOf(), rows)
            override suspend fun processRelationshipSearchIndex(maximumUsers: Int) = true
            override suspend fun relationshipPage(viewer: UserId, request: RelationshipPageRequest) = source().relationshipPage(viewer, request)
            override suspend fun relationshipWindow(viewer: UserId, request: RelationshipPageRequest, anchor: RelationshipAnchor, precedingCount: Int) = source().relationshipWindow(viewer, request, anchor, precedingCount)
        }
        val session = SessionUi.SignedIn(actor)
        // Neither the relationship list nor a discovery name is a real-mode display source.
        val state = AppState(session = session, snapshot = ClientSnapshot(contacts = persistentListOf(Contact(user(1), "不得泄露的发现名称", ""))))
        var active by mutableStateOf(true)
        var page: RelationshipPageSession? = null
        var route: Route? = null
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            val owner = rememberCoroutineScope()
            MaterialTheme { SocialRequestsPage(state, session, active,
                { RelationshipPageSession(store, actor, owner, changes).also { page = it } }, { null }, { _, _ -> }, {}, {}, {}, { route = it }) }
        }
        compose.waitUntil(5000) { page?.state?.value?.page?.relationships?.size == 50 }
        compose.onNodeWithText("不得泄露的发现名称").assertDoesNotExist()
        compose.onNodeWithTag("requests-next").performClick()
        compose.waitUntil(5000) { page?.state?.value?.page?.relationships?.firstOrNull()?.target == user(51) }
        compose.onNodeWithTag("requests-list").performScrollToIndex(24); compose.waitForIdle()
        compose.onNodeWithTag("requests-row-${user(75).value}").assertIsDisplayed()
        val incoming = page
        compose.onNodeWithTag("requests-outgoing").performClick()
        compose.waitUntil(5000) { page !== incoming && page?.state?.value?.request?.scope == RelationshipPageScope.Outgoing && page?.state?.value?.page?.relationships?.size == 50 }
        assertTrue(incoming!!.state.value.closed)
        compose.onNodeWithTag("requests-profile-${user(201).value}").performClick()
        assertEquals(Route.Profile(user(201).value), route)
        compose.onNodeWithTag("requests-incoming").performClick()
        compose.waitUntil(5000) { page?.state?.value?.navigation?.target == user(75) }
        compose.onNodeWithTag("requests-row-${user(75).value}").assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore()
        compose.waitUntil(5000) { page?.state?.value?.navigation?.target == user(75) }
        compose.onNodeWithTag("requests-row-${user(75).value}").assertIsDisplayed()
        compose.runOnIdle { rows = rows.filter { it.target != user(75) }.toPersistentList(); changes.value++ }
        compose.waitUntil(5000) { page?.state?.value?.navigation?.target == user(76) }
        compose.onNodeWithTag("requests-row-${user(76).value}").assertIsDisplayed()
        val retired = page
        compose.runOnIdle { active = false }; compose.waitForIdle(); assertTrue(retired!!.state.value.closed)
        compose.runOnIdle { active = true }
        try {
            compose.waitUntil(5000) { page !== retired && page?.state?.value?.navigation?.target == user(76) }
        } catch (failure: Throwable) {
            throw AssertionError("Restored navigation: ${page?.state?.value?.navigation}; first: ${page?.state?.value?.page?.relationships?.firstOrNull()?.target}; scope: ${page?.state?.value?.request?.scope}", failure)
        }
        compose.onNodeWithTag("requests-first").performClick()
        compose.waitUntil(5000) { page?.state?.value?.page?.relationships?.firstOrNull()?.target == user(1) }
        compose.onNodeWithTag("requests-operations").performClick(); compose.waitForIdle()
        assertTrue(page!!.state.value.closed); compose.onNodeWithText("暂无操作记录").assertIsDisplayed()
        compose.runOnIdle { active = false }
    }

    @Test fun demoDirectionsKeepActionAndRecoveryCallbacksAndNeverOpenRealReaders() {
        val session = SessionUi.SignedIn(actor, demo = true)
        val proposal = SocialProposal(user(800).value, actor, user(1), SocialAction.Accept)
        val work = SocialWork(SocialCommand(actor, user(3), user(801).value, SocialAction.Remove, 1, 10_000), SocialWorkStatus.NeedsAttention)
        val snapshot = ClientSnapshot(contacts = persistentListOf(Contact(user(1), "李晓", "lixiao"), Contact(user(2), "周宁", "zhouning")),
            relationships = persistentListOf(Relationship(user(1), RelationshipState.Pending, user(1), 8), Relationship(user(2), RelationshipState.Pending, actor, 9)),
            socialProposals = persistentListOf(proposal), socialOperations = persistentListOf(work))
        var action: Pair<UserId, SocialAction>? = null; var prepared: String? = null; var discarded: String? = null; var retried: String? = null
        compose.setContent { MaterialTheme { SocialRequestsPage(AppState(session = session, snapshot = snapshot), session, true,
            { error("demo opened real relationships") }, { error("demo opened real profiles") }, { id, value -> action = id to value },
            { prepared = it }, { discarded = it }, { retried = it }, {}) } }
        compose.waitUntil(5000) { compose.onAllNodesWithText("李晓").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("周宁").assertDoesNotExist()
        compose.onNodeWithText("接受", substring = false).performClick(); assertEquals(user(1) to SocialAction.Accept, action)
        compose.onNodeWithText("拒绝", substring = false).performClick(); assertEquals(user(1) to SocialAction.Reject, action)
        InstrumentationRegistry.getInstrumentation().targetContext.openFileOutput("social-requests-page.png", 0).use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        compose.onNodeWithTag("requests-outgoing").performClick()
        compose.waitUntil(5000) { compose.onAllNodesWithText("周宁").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("李晓").assertDoesNotExist()
        compose.onNodeWithText("取消申请").performClick(); assertEquals(user(2) to SocialAction.Remove, action)
        compose.onNodeWithTag("requests-operations").performClick()
        compose.onNodeWithText("继续确认").performClick(); assertEquals(proposal.id, prepared)
        compose.onNodeWithText("取消操作").performClick(); assertEquals(proposal.id, discarded)
        compose.onNodeWithText("重试").performScrollTo().performClick(); assertEquals(work.command.operation, retried)
    }

    @Test fun visibleRequestsUseRelationshipAuthorityAndDropNamesOnRetirement() {
        val session = SessionUi.SignedIn(actor)
        val device = DeviceId(user(900).value)
        val calls = mutableListOf<ProfileKey>()
        var active by mutableStateOf(true)
        var closed = 0
        val store = DemoRelationshipPages(persistentListOf(), (1..60).map {
            Relationship(user(it), RelationshipState.Pending, user(it), 1)
        }.toPersistentList())
        compose.setContent {
            val owner = rememberCoroutineScope()
            MaterialTheme { SocialRequestsPage(AppState(session = session, snapshot = ClientSnapshot(presentationGeneration = "one")), session, active,
                { RelationshipPageSession(store, actor, owner) }, {
                    ProfilePresentationPage(actor, device, ProfilePresentationReading { keys ->
                        calls.addAll(keys)
                        keys.map { key -> ProfileReadResult.Available(AuthorizedProfile(
                            ProfileView(key.user, PublicIdentity(key.user, PublicHandle("friend"), "已授权姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
                            ProfileLease(actor, device, key, 1, 1, 0, ProfileAuthority(1, null, 0, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
                        }.toPersistentList()
                    }, { keys -> ProfileFenceSnapshot("one", keys.associateWith { ProfileFence() }.toPersistentMap()) }, owner, onClose = { closed++ })
                }, { _, _ -> }, {}, {}, {}, {}) }
        }
        compose.waitUntil(5000) { compose.onAllNodesWithText("已授权姓名").fetchSemanticsNodes().isNotEmpty() }
        compose.runOnIdle {
            assertTrue(calls.isNotEmpty())
            assertTrue(calls.all { it.context == ProfileContext.Relationship })
            assertTrue(calls.map { it.user }.distinct().size < 50)
            assertFalse(calls.any { it.user == user(50) })
            active = false
        }
        compose.onAllNodesWithText("已授权姓名").assertCountEquals(0)
        compose.runOnIdle { assertEquals(1, closed) }
    }

    @Test fun failedQueryCanRetryAndPendingOperationDisablesTheRelationshipAction() {
        val session = SessionUi.SignedIn(actor)
        var fail = true; var page: RelationshipPageSession? = null
        val store = object: RelationshipPageStore {
            override suspend fun processRelationshipSearchIndex(maximumUsers: Int) = true
            override suspend fun relationshipPage(viewer: UserId, request: RelationshipPageRequest): RelationshipPage {
                if (fail) throw IllegalStateException("fixture")
                return RelationshipPage(persistentListOf(Relationship(user(1), RelationshipState.Pending, user(1), 1)))
            }
        }
        val work = SocialWork.fresh(SocialCommand(actor, user(1), user(802).value, SocialAction.Accept, 1, 10_000))
        compose.setContent {
            val owner = rememberCoroutineScope()
            MaterialTheme { SocialRequestsPage(AppState(session = session, snapshot = ClientSnapshot(socialOperations = persistentListOf(work))), session, true,
                { RelationshipPageSession(store, actor, owner).also { page = it } }, { null }, { _, _ -> error("pending action submitted") }, {}, {}, {}, {}) }
        }
        compose.waitUntil(5000) { page?.state?.value?.feedback != null }
        compose.onNodeWithText("暂无待处理申请").assertDoesNotExist()
        compose.runOnIdle { fail = false }
        compose.onNodeWithTag("requests-retry").performClick()
        compose.waitUntil(5000) { page?.state?.value?.page?.relationships?.size == 1 }
        compose.onAllNodesWithText("等待操作确认").assertCountEquals(2)
        compose.onAllNodesWithText("等待操作确认")[0].assertIsNotEnabled()
        compose.onAllNodesWithText("等待操作确认")[1].assertIsNotEnabled()
    }
}
