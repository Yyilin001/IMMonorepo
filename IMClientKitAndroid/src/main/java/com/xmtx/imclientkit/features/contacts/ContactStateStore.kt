package com.xmtx.imclientkit.features.contacts

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

class ContactStateStore {
    private val mutableState = MutableStateFlow(ContactState())
    val state: StateFlow<ContactState> = mutableState

    fun restoreSnapshot(snapshot: ContactState) {
        mutableState.value = snapshot.copy(isLoading = false, statusMessage = null)
    }

    fun setLoading(isLoading: Boolean) {
        mutableState.update { it.copy(isLoading = isLoading) }
    }

    fun setStatusMessage(message: String?) {
        mutableState.update { it.copy(statusMessage = message, isLoading = false) }
    }

    fun replaceContacts(contacts: List<ContactResponseBody>) {
        mutableState.update {
            it.copy(
                contacts = contacts.sortedBy { contact -> contact.preferredDisplayName.lowercase() },
                isLoading = false,
                statusMessage = null,
            )
        }
    }

    fun upsertContact(contact: ContactResponseBody) {
        mutableState.update { current ->
            current.copy(
                contacts = current.contacts
                    .filterNot { it.id == contact.id }
                    .plus(contact)
                    .sortedBy { it.preferredDisplayName.lowercase() },
                incomingRequests = current.incomingRequests.filterNot { it.peerUser(null).id == contact.id },
                outgoingRequests = current.outgoingRequests.filterNot { it.peerUser(null).id == contact.id },
                statusMessage = null,
            )
        }
    }

    fun removeContact(userID: String) {
        mutableState.update { current ->
            current.copy(contacts = current.contacts.filterNot { it.id == userID })
        }
    }

    fun replaceRequests(requests: List<ContactRequestResponseBody>, currentUserID: String?) {
        mutableState.update { current ->
            current.copy(
                incomingRequests = requests.pendingIncoming(currentUserID),
                outgoingRequests = requests.pendingOutgoing(currentUserID),
                resolvedRequests = requests.filterNot { it.status == ContactRequestStatus.pending }
                    .sortedByDescending { it.updatedAt ?: it.createdAt.orEmpty() },
                isLoading = false,
                statusMessage = null,
            )
        }
    }

    fun upsertRequest(request: ContactRequestResponseBody, currentUserID: String?) {
        val all = (state.value.incomingRequests + state.value.outgoingRequests + state.value.resolvedRequests)
            .filterNot { it.id == request.id } + request
        replaceRequests(all, currentUserID)
    }

    private fun List<ContactRequestResponseBody>.pendingIncoming(currentUserID: String?): List<ContactRequestResponseBody> =
        filter { it.status == ContactRequestStatus.pending && it.addressee.id == currentUserID }
            .sortedByDescending { it.createdAt.orEmpty() }

    private fun List<ContactRequestResponseBody>.pendingOutgoing(currentUserID: String?): List<ContactRequestResponseBody> =
        filter { it.status == ContactRequestStatus.pending && it.requester.id == currentUserID }
            .sortedByDescending { it.createdAt.orEmpty() }
}
