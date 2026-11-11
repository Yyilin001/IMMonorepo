package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.coroutines.CompletableDeferred
import org.junit.Rule
import org.junit.Test

class DiscoveryPageTests {
    @get:Rule val compose = createComposeRule()
    private val session = SessionUi.SignedIn(UserId("me"), true)
    private fun lookup() = IdentityLookup(PublicIdentity(UserId("friend"), PublicHandle("alice"), "Alice", AccountKind.Regular), System.nanoTime() + 60_000_000_000)
    @Test fun lookupPermissionClearsOnExitAndLateResultCannotResurrectIt() {
        val active = mutableStateOf(true)
        var response = CompletableDeferred<IdentityLookup?>()
        compose.setContent { MaterialTheme {
            DiscoveryPage(AppState(session = session), session, active.value, { response.await() }, { null }, {}, {})
        } }
        compose.onNodeWithText("公开标识，例如 @lin").performTextInput("alice")
        compose.onNodeWithText("查找").performClick()
        compose.runOnIdle { response.complete(lookup()) }
        compose.onNodeWithText("Alice").assertIsDisplayed()
        compose.runOnIdle { active.value = false }
        compose.onNodeWithText("Alice").assertDoesNotExist()
        compose.runOnIdle { active.value = true; response = CompletableDeferred() }
        compose.onNodeWithText("查找").performClick()
        compose.runOnIdle { active.value = false }
        compose.waitForIdle()
        compose.runOnIdle { active.value = true }
        compose.waitForIdle()
        compose.runOnIdle { response.complete(lookup()) }
        compose.onNodeWithText("Alice").assertDoesNotExist()
    }
    @Test fun selectedLookupPassesCompleteIdentityToDurableCreation() {
        val found = lookup(); var chosen: PublicIdentity? = null
        compose.setContent { MaterialTheme {
            DiscoveryPage(AppState(session = session), session, true, { found }, { chosen = it; null }, {}, {})
        } }
        compose.onNodeWithText("公开标识，例如 @lin").performTextInput("alice")
        compose.onNodeWithText("查找").performClick()
        compose.onNodeWithText("Alice").assertIsDisplayed()
        compose.onNodeWithText("发消息").performClick()
        compose.runOnIdle { org.junit.Assert.assertEquals(found.identity, chosen) }
    }

}
