package com.xmtx.imappandroid

import com.xmtx.imappandroid.viewmodel.ConversationManagementViewModel
import com.xmtx.imclientkit.features.im.IMConversationKind
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ConversationManagementViewModelTests {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun createGroupParsesEmailsAndDelegates() = runTest {
        val gateway = FakeSessionGateway()
        val viewModel = ConversationManagementViewModel(gateway)

        viewModel.updateTitle("Project")
        viewModel.updateMemberEmails("a@example.com, b@example.com\nc@example.com")
        viewModel.createGroup()

        assertEquals(
            Triple(IMConversationKind.Group, "Project", listOf("a@example.com", "b@example.com", "c@example.com")),
            gateway.createdConversation,
        )
    }
}
