package com.xmtx.imappandroid

import com.xmtx.imappandroid.viewmodel.ContactsViewModel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ContactsViewModelTests {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun loadContactsDelegatesToGateway() = runTest {
        val gateway = FakeSessionGateway()
        val viewModel = ContactsViewModel(gateway)

        viewModel.loadContacts()

        assertEquals(true, gateway.didReloadContacts)
    }

    @Test
    fun sendRequestDelegatesAndClearsInputs() = runTest {
        val gateway = FakeSessionGateway()
        val viewModel = ContactsViewModel(gateway)

        viewModel.updateEmail("friend@example.com")
        viewModel.updateMessage("hi")
        viewModel.updateRemark("Friend")
        viewModel.sendRequest()

        assertEquals(Triple("friend@example.com", "hi", "Friend"), gateway.sentContactRequest)
        assertEquals("", viewModel.state.value.email)
    }
}
