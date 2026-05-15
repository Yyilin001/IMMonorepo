package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.contacts.ContactRequestResponseBody
import com.xmtx.imclientkit.features.contacts.ContactResponseBody
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

data class ContactsUiState(
    val contacts: List<ContactResponseBody> = emptyList(),
    val incomingRequests: List<ContactRequestResponseBody> = emptyList(),
    val outgoingRequests: List<ContactRequestResponseBody> = emptyList(),
    val email: String = "",
    val messageText: String = "",
    val remark: String = "",
    val isLoading: Boolean = false,
    val message: String? = null,
)

class ContactsViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ContactsUiState())
    val state: StateFlow<ContactsUiState> = mutableState

    init {
        viewModelScope.launch {
            gateway.contactState.collect { contactState ->
                mutableState.value = mutableState.value.copy(
                    contacts = contactState.contacts,
                    incomingRequests = contactState.incomingRequests,
                    outgoingRequests = contactState.outgoingRequests,
                    isLoading = contactState.isLoading,
                    message = contactState.statusMessage,
                )
            }
        }
    }

    fun loadContacts() {
        gateway.reloadContacts()
    }

    fun updateEmail(email: String) {
        mutableState.value = mutableState.value.copy(email = email)
    }

    fun updateMessage(message: String) {
        mutableState.value = mutableState.value.copy(messageText = message)
    }

    fun updateRemark(remark: String) {
        mutableState.value = mutableState.value.copy(remark = remark)
    }

    fun sendRequest() {
        val email = state.value.email.trim()
        if (email.isEmpty()) return
        gateway.sendContactRequest(
            email = email,
            message = state.value.messageText.trim().takeIf { it.isNotEmpty() },
            remark = state.value.remark.trim().takeIf { it.isNotEmpty() },
        )
        mutableState.value = mutableState.value.copy(email = "", messageText = "", remark = "")
    }

    fun accept(requestID: String) {
        gateway.acceptContactRequest(requestID, remark = null)
    }

    fun decline(requestID: String) {
        gateway.declineContactRequest(requestID)
    }
}
