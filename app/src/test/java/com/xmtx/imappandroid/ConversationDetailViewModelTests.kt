package com.xmtx.imappandroid

import com.xmtx.imappandroid.viewmodel.ConversationDetailViewModel
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversation
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ConversationDetailViewModelTests {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun openConversationDelegatesToGateway() = runTest {
        val gateway = FakeSessionGateway()
        val viewModel = ConversationDetailViewModel(gateway)

        viewModel.openConversation("conversation-1")

        assertEquals("conversation-1", gateway.openedConversationID)
    }

    @Test
    fun sendTextDelegatesToGatewayAndClearsDraft() = runTest {
        val gateway = FakeSessionGateway()
        gateway.reloadConversations()
        val viewModel = ConversationDetailViewModel(gateway)
        viewModel.openConversation("conversation-1")
        viewModel.updateDraft("hello")

        viewModel.sendText()

        assertEquals("hello" to "conversation-1", gateway.sentText)
        assertEquals("", viewModel.state.value.draftText)
    }
}
