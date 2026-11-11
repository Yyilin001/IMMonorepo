package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.UserId
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class InvitationNavigationTests {
    @get:Rule val compose = createComposeRule()
    private val user = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val link = "iim://group-invite?token=${"A".repeat(43)}"

    private class Owner : LifecycleOwner {
        override val lifecycle = LifecycleRegistry(this)
    }

    private fun fixture(demo: Boolean = false, test: Fixture.() -> Unit) {
        val application = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val model = AppViewModel(application)
        val models = ViewModelStore().apply { put("invitation-navigation", model) }
        val fixture = Fixture(model, SessionUi.SignedIn(user, demo = demo))
        try {
            compose.runOnIdle { fixture.owner.lifecycle.currentState = Lifecycle.State.RESUMED }
            fixture.restore.setContent {
                fixture.stack = rememberNavBackStack(Route.Home)
                CompositionLocalProvider(LocalLifecycleOwner provides fixture.owner) {
                    MaterialTheme { SignedIn(fixture.app, fixture.session, model, fixture.stack) }
                }
            }
            fixture.test()
        } finally {
            compose.runOnIdle {
                model.invitationInbox.clear()
                fixture.owner.lifecycle.currentState = Lifecycle.State.DESTROYED
                models.clear()
            }
        }
    }

    private inner class Fixture(val model: AppViewModel, val session: SessionUi.SignedIn) {
        val owner = Owner()
        val restore = StateRestorationTester(compose)
        var app by mutableStateOf(AppState(session = session))
        lateinit var stack: NavBackStack<NavKey>
        fun offer() = model.invitationInbox.offer(link)
        fun assertStack(vararg routes: Route) = compose.runOnIdle { assertEquals(routes.toList(), stack.toList()) }
    }

    @Test fun invitationWaitsForForegroundThenReturnsToMessagesAfterRestoration() = fixture {
        compose.onNodeWithTag("root-tab-Contacts").performClick()
        compose.runOnIdle {
            owner.lifecycle.currentState = Lifecycle.State.STARTED
            offer()
        }
        assertStack(Route.Home)
        compose.onNodeWithTag("root-tab-Contacts").assertIsSelected()
        compose.runOnIdle { owner.lifecycle.currentState = Lifecycle.State.RESUMED }
        compose.onNodeWithTag("invitation-page").assertIsDisplayed()
        assertStack(Route.Home, Route.Page(PageKind.JoinGroup))
        // This navigation fixture has no account service; explicitly consume its pending handoff.
        compose.runOnIdle { model.invitationInbox.clear() }
        restore.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("invitation-page").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        compose.onNodeWithTag("root-tab-Contacts").assertIsNotSelected()
    }

    @Test fun busyOperationDefersInvitationAndExistingEntryIsReused() = fixture {
        val invitation = Route.Page(PageKind.JoinGroup)
        compose.onNodeWithTag("root-tab-Account").performClick()
        compose.runOnIdle {
            app = app.copy(securityBusy = true)
            stack.add(invitation)
            stack.add(Route.Page(PageKind.Connection))
            offer()
        }
        assertStack(Route.Home, invitation, Route.Page(PageKind.Connection))
        compose.runOnIdle { app = app.copy(securityBusy = false) }
        compose.onNodeWithTag("invitation-page").assertIsDisplayed()
        assertStack(Route.Home, invitation)
        compose.runOnIdle { offer() }
        assertStack(Route.Home, invitation)
        compose.runOnIdle { model.invitationInbox.clear() }
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }

    @Test fun demoKeepsInvitationPendingAndDoesNotNavigateOrChangeTabs() = fixture(demo = true) {
        compose.onNodeWithTag("root-tab-Contacts").performClick()
        compose.runOnIdle { offer() }
        assertStack(Route.Home)
        compose.onNodeWithTag("root-tab-Contacts").assertIsSelected()
        compose.runOnIdle { assertNotNull(model.invitationInbox.ticket.value) }
    }
}
