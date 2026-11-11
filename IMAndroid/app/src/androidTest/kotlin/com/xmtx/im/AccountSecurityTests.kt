package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import com.xmtx.im.client.PasswordAction
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.IOException

class AccountSecurityTests {
    @get:Rule val compose = createComposeRule()
    private fun fillChange() {
        securityField("security-account").performTextInput("account")
        securityField("security-current").performTextInput("current-password")
        securityField("security-next").performTextInput("replacement-password")
        securityField("security-confirmation").performTextInput("replacement-password")
    }
    private fun securityField(tag: String): SemanticsNodeInteraction {
        compose.onNodeWithTag("security-form").performScrollToNode(hasTestTag(tag))
        return compose.onNodeWithTag(tag)
    }
    private fun securityText(text: String): SemanticsNodeInteraction {
        compose.onNodeWithTag("security-form").performScrollToNode(hasText(text))
        return compose.onNodeWithText(text)
    }
    @Test fun recoveryCodeGeneratorFailureDoesNotSubmitOrCrashAndCanBeRetried() {
        var generations = 0; var submissions = 0
        compose.setContent { MaterialTheme { AccountSecurityPage(true, initialAction = PasswordAction.RecoveryCode,
            generateCode = { generations++; if(generations == 1) throw IllegalStateException() else "a".repeat(64) }) { _, _, _, _, _ -> submissions++ } } }
        securityText("生成恢复码").performClick()
        securityField("security-feedback").assertTextEquals("无法生成恢复码，请稍后重试。")
        securityText("生成恢复码").performClick()
        securityField("security-generated-code").assertExists()
        securityField("security-submit").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(2, generations); assertEquals(0, submissions) }
    }
    @Test fun lostReplyStaysUnknownAcrossRestorationWithoutAutomaticRetry() {
        val restoration = StateRestorationTester(compose); var calls = 0
        restoration.setContent { MaterialTheme { AccountSecurityPage(true, generateCode = { "a".repeat(64) }) { _, _, _, _, _ -> calls++; throw IOException() } } }
        fillChange(); securityField("security-submit").performClick()
        securityField("security-feedback").assertTextContains("先用刚提交的新密码登录核验", substring = true)
        restoration.emulateSavedInstanceStateRestore()
        securityField("security-feedback").assertTextContains("先用刚提交的新密码登录核验", substring = true)
        securityField("security-submit").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(1, calls) }
    }
    @Test fun disposingInFlightRecoveryCodeRetainsUncertaintyAndRequiresOriginalSavedCode() {
        val restoration = StateRestorationTester(compose); val gate = CompletableDeferred<Unit>(); var calls = 0
        restoration.setContent { MaterialTheme { AccountSecurityPage(true, initialAction = PasswordAction.RecoveryCode, generateCode = { "a".repeat(64) }) { _, _, _, _, _ -> calls++; gate.await() } } }
        securityField("security-account").performTextInput("account")
        securityField("security-current").performTextInput("current-password")
        securityText("生成恢复码").performClick()
        securityField("security-saved").performClick()
        securityField("security-submit").performClick()
        compose.runOnIdle { assertEquals(1, calls) }
        restoration.emulateSavedInstanceStateRestore(); gate.complete(Unit)
        securityField("security-feedback").assertTextContains("稍后用同一码重试", substring = true)
        compose.onNodeWithText("生成恢复码").assertDoesNotExist()
        securityField("security-code").assertExists()
        securityField("security-submit").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(1, calls) }
    }
}
