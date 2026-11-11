package com.xmtx.im

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.InvitationSecret
import com.xmtx.im.client.invitationURL
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class InvitationEntryTests {
    @get:Rule val compose = createEmptyComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val first = invitationURL(InvitationSecret("A".repeat(43)))
    private val second = invitationURL(InvitationSecret("B".repeat(43)))
    private fun link(value: String) = Intent(Intent.ACTION_VIEW, Uri.parse(value)).setPackage(context.packageName)
        .addCategory(Intent.CATEGORY_BROWSABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    @Test fun coldAndWarmExternalIntentsAreSanitizedAndIgnoredLinksDoNotReplayOnRecreation() {
        val intent = link(first).putExtra("untrusted", first)
        assertTrue(context.packageManager.queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            .any { it.activityInfo.name == MainActivity::class.java.name })
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var activity: MainActivity? = null
        fun resumed(): MainActivity? {
            var value: MainActivity? = null
            instrumentation.runOnMainSync {
                value = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>().singleOrNull()
            }
            return value
        }
        fun onActivity(block: (MainActivity) -> Unit) = instrumentation.runOnMainSync { block(requireNotNull(activity)) }
        fun recreate() {
            val before = activity
            onActivity { it.recreate() }
            compose.waitUntil(10000) { resumed()?.takeIf { it !== before }?.also { activity = it } != null }
        }
        // Observe by Activity identity: ActivityScenario's Intent matching stops matching after sanitization.
        context.startActivity(intent)
        try {
            compose.waitUntil(10000) { resumed()?.also { activity = it } != null }
            compose.waitUntil(15000) { compose.onAllNodesWithTag("pending-invitation").fetchSemanticsNodes().isNotEmpty() }
            var originalTicket: String? = null
            onActivity {
                originalTicket = ViewModelProvider(it)[AppViewModel::class.java].invitationInbox.ticket.value
                assertNotNull(originalTicket); assertNull(it.intent.data); assertNull(it.intent.extras)
            }
            recreate()
            onActivity { assertEquals(originalTicket, ViewModelProvider(it)[AppViewModel::class.java].invitationInbox.ticket.value) }
            context.startActivity(link(first)); compose.waitForIdle()
            onActivity { assertEquals(originalTicket, ViewModelProvider(it)[AppViewModel::class.java].invitationInbox.ticket.value) }
            context.startActivity(link(second))
            compose.waitUntil(5000) {
                var changed = false
                onActivity { changed = ViewModelProvider(it)[AppViewModel::class.java].invitationInbox.ticket.value != originalTicket }
                changed
            }
            compose.onNodeWithText("忽略邀请").performScrollTo().performClick()
            compose.onNodeWithTag("pending-invitation").assertDoesNotExist()
            recreate()
            compose.onNodeWithTag("pending-invitation").assertDoesNotExist()
            context.startActivity(link(first + "&token=ambiguous"))
            compose.waitForIdle()
            onActivity {
                assertNull(ViewModelProvider(it)[AppViewModel::class.java].invitationInbox.ticket.value)
                assertNull(it.intent.data)
            }
        } finally {
            onActivity { it.finish() }
            compose.waitUntil(10000) { resumed() == null }
        }
    }

    @Test fun inboxKeepsOnlyLatestTicketAndCannotReplayConsumedOrCancelledBearer() {
        val inbox = InvitationInbox()
        inbox.offer(first); val a = requireNotNull(inbox.ticket.value)
        inbox.offer(first); assertEquals(a, inbox.ticket.value)
        inbox.offer("not a link"); assertEquals(a, inbox.ticket.value)
        inbox.offer(second); val b = requireNotNull(inbox.ticket.value)
        assertNotEquals(a,b); assertNull(inbox.take(a))
        assertEquals(InvitationSecret("B".repeat(43)), inbox.take(b))
        assertNull(inbox.ticket.value); assertNull(inbox.take(b))
        inbox.offer(first); inbox.clear(); assertNull(inbox.ticket.value); assertNull(inbox.take(a))
        assertNull(InvitationInbox().ticket.value)
    }
}
