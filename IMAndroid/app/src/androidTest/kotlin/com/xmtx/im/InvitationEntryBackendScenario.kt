package com.xmtx.im

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.test.ext.junit.rules.ActivityScenarioRule
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*

internal suspend fun prepareInvitationEntryFixture(context: Context, endpoint: String, owner: Credentials,
    store: SqliteClientStore, api: AuthenticatedTransport, run: String): InvitationLink {
    val creator = GroupCreationService(owner.userId, GroupCreationClient(api), store)
    val creation = creator.prepare("链接邀请 $run", persistentListOf())
    withTimeout(30000) {
        while (!store.groupWorks().first { it.command.operation == creation.command.operation }.terminal) {
            creator.flush(); delay(100)
        }
    }
    val room = requireNotNull(store.groupWorks().first { it.command.operation == creation.command.operation }.room)
    val client = InvitationClient(api)
    val service = InvitationService(owner.userId, client, store, KeystoreInvitationSecrets(context, endpoint, owner.userId, owner.deviceId))
    val work = service.enqueue(service.confirmation(room, InvitationAction.Create(600,5,client.baseline(room))))
    withTimeout(30000) {
        while (!store.invitationWorks().first { it.intent.key == work.intent.key }.terminal) {
            service.flush(); delay(100)
        }
    }
    assertEquals(InvitationStatus.Committed, store.invitationWorks().first { it.intent.key == work.intent.key }.status)
    return InvitationDirectory(api).links(room).single()
}

internal fun verifyInvitationEntryUi(
    compose: AndroidComposeTestRule<ActivityScenarioRule<ComponentActivity>, ComponentActivity>,
    model: AppViewModel, link: InvitationLink, owner: InvitationDirectory, restoration: StateRestorationTester,
) {
    fun waitFor(predicate: () -> Boolean) = compose.waitUntil(30000, predicate)
    fun scroll(text: String) = compose.onNodeWithTag("invitation-page").performScrollToNode(hasText(text))
    fun requests() = runBlocking { owner.requests(link.room).requests }
    waitFor { compose.onAllNodesWithText(link.title).fetchSemanticsNodes().isNotEmpty() }
    assertNull(model.invitationInbox.ticket.value)
    assertTrue(requests().isEmpty())
    compose.onNodeWithText("我的", useUnmergedTree=true).assertDoesNotExist()
    scroll("申请加入"); compose.onNodeWithText("申请加入").performClick()
    compose.onNodeWithText("申请加入？").assertIsDisplayed()
    compose.onNodeWithText("取消").performClick()
    assertTrue(requests().isEmpty())
    compose.onNodeWithText("申请加入").performClick()
    compose.onNodeWithText("确认").performClick()
    waitFor { compose.onAllNodesWithText("申请等待审批").fetchSemanticsNodes().isNotEmpty() }
    assertEquals(1, requests().size)
    scroll("撤回申请"); compose.onNodeWithText("撤回申请").performClick()
    compose.onNodeWithText("确认").performClick()
    waitFor { compose.onAllNodesWithText("申请已撤回").fetchSemanticsNodes().isNotEmpty() }
    assertTrue(requests().isEmpty())
    // A new delivery while this page is open reuses the same detail entry.
    compose.runOnUiThread { model.invitationInbox.offer(invitationURL(link.secret)) }
    waitFor { model.invitationInbox.ticket.value == null }
    waitFor { compose.onAllNodesWithText(link.title).fetchSemanticsNodes().isNotEmpty() }
    restoration.emulateSavedInstanceStateRestore()
    assertEquals("", compose.onNodeWithTag("invite-input").fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
    compose.onNodeWithText(link.title).assertDoesNotExist()
    assertNull(model.invitationInbox.ticket.value)
    compose.runOnUiThread { model.invitationInbox.offer(invitationURL(link.secret)) }
    waitFor { compose.onAllNodesWithText(link.title).fetchSemanticsNodes().isNotEmpty() }
    compose.onNodeWithContentDescription("返回").performClick()
    compose.onNodeWithText("联系人", useUnmergedTree=true).assertIsDisplayed()
    compose.onNodeWithTag("invitation-page").assertDoesNotExist()
}
