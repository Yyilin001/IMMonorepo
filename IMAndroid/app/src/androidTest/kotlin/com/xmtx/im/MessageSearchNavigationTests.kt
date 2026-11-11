package com.xmtx.im

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test

class MessageSearchNavigationTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun resultCarriesOnlyMessageIdentityAndBackRestoresSearchQuery() {
        compose.waitUntil(15000) {compose.onAllNodesWithText("体验界面（离线演示）").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("体验界面（离线演示）").performScrollTo().performClick()
        compose.onNodeWithText("搜索").performClick()
        compose.onNodeWithTag("message-search-query").performTextInput("想法")
        compose.waitUntil(5000) {compose.onAllNodesWithTag("message-search-hit-sample-1").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithTag("message-search-hit-sample-1").performClick()
        compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
        compose.activityRule.scenario.recreate();compose.onNodeWithTag("chat-focused-message").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("message-search-query").assertTextContains("想法")
        compose.waitUntil(5000) {runCatching {compose.onNodeWithTag("message-search-hit-sample-1").assertIsDisplayed()}.isSuccess}
        compose.onNodeWithTag("message-search-hit-sample-1").assertIsDisplayed()
    }
}
