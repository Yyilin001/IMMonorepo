package com.xmtx.imappandroid

import com.xmtx.imappandroid.viewmodel.ConversationListViewModel
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ConversationListViewModelTests {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun loadConversationsPublishesItems() = runTest {
        val page = IMConversationSummaryPageResponseBody(
            items = listOf(conversation("conversation-1")),
            hasMore = false,
            snapshotToken = "snapshot",
        )
        val viewModel = ConversationListViewModel(FakeSessionGateway(conversationPageResult = Result.success(page)))

        viewModel.loadConversations()

        assertFalse(viewModel.state.value.isLoading)
        assertEquals(1, viewModel.state.value.conversations.size)
        assertEquals("conversation-1", viewModel.state.value.conversations.first().id)
    }

    @Test
    fun loadConversationsPublishesFailureMessage() = runTest {
        val viewModel = ConversationListViewModel(
            FakeSessionGateway(
                conversationPageResult = Result.failure(IllegalStateException("offline")),
            ),
        )

        viewModel.loadConversations()

        assertFalse(viewModel.state.value.isLoading)
        assertTrue(viewModel.state.value.conversations.isEmpty())
        assertEquals("offline", viewModel.state.value.message)
    }
}
