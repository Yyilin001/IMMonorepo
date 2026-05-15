package com.xmtx.imclientkit.features.contacts

import com.xmtx.imclientkit.SessionClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class ContactRuntimeController(
    private val sessionClient: SessionClient,
    val contactStore: ContactStateStore,
    private val cache: ContactStateCaching = NoopContactStateCache(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private var currentUserID: String? = null
    private var cacheObserveJob: Job? = null
    private var cacheSaveJob: Job? = null

    fun start(userID: String) {
        currentUserID = userID
        startCachePersistence(userID)
        scope.launch {
            restoreCachedSnapshot(userID)
            refreshAll()
        }
    }

    fun stop() {
        currentUserID = null
        cacheObserveJob?.cancel()
        cacheObserveJob = null
    }

    fun refreshAll() {
        scope.launch {
            contactStore.setLoading(true)
            runCatching {
                val contacts = sessionClient.fetchContacts()
                val requests = sessionClient.fetchContactRequests(ContactRequestBox.All)
                contacts to requests
            }.onSuccess { (contacts, requests) ->
                contactStore.replaceContacts(contacts)
                contactStore.replaceRequests(requests, currentUserID)
            }.onFailure { error ->
                contactStore.setStatusMessage(error.message ?: "Failed to load contacts.")
            }
        }
    }

    fun addContact(email: String, remark: String? = null) {
        scope.launch {
            runCatching { sessionClient.addContact(email, remark) }
                .onSuccess { contactStore.upsertContact(it) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to add contact.") }
        }
    }

    fun updateContact(contactUserID: String, remark: String?) {
        scope.launch {
            runCatching { sessionClient.updateContact(contactUserID, remark) }
                .onSuccess { contactStore.upsertContact(it) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to update contact.") }
        }
    }

    fun deleteContact(contactUserID: String) {
        scope.launch {
            runCatching { sessionClient.deleteContact(contactUserID) }
                .onSuccess { contactStore.removeContact(contactUserID) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to delete contact.") }
        }
    }

    fun sendContactRequest(email: String, message: String? = null, remark: String? = null) {
        scope.launch {
            runCatching { sessionClient.sendContactRequest(email, message, remark) }
                .onSuccess { contactStore.upsertRequest(it, currentUserID) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to send request.") }
        }
    }

    fun acceptContactRequest(requestID: String, remark: String? = null) {
        scope.launch {
            runCatching { sessionClient.acceptContactRequest(requestID, remark) }
                .onSuccess {
                    contactStore.upsertContact(it)
                    refreshAll()
                }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to accept request.") }
        }
    }

    fun declineContactRequest(requestID: String) {
        scope.launch {
            runCatching { sessionClient.declineContactRequest(requestID) }
                .onSuccess { contactStore.upsertRequest(it, currentUserID) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to decline request.") }
        }
    }

    fun cancelContactRequest(requestID: String) {
        scope.launch {
            runCatching { sessionClient.cancelContactRequest(requestID) }
                .onSuccess { contactStore.upsertRequest(it, currentUserID) }
                .onFailure { contactStore.setStatusMessage(it.message ?: "Failed to cancel request.") }
        }
    }

    fun handleContactEvent() {
        refreshAll()
    }

    private fun startCachePersistence(userID: String) {
        cacheObserveJob?.cancel()
        cacheObserveJob = scope.launch {
            var skippedInitial = false
            contactStore.state.collect { state ->
                if (!skippedInitial) {
                    skippedInitial = true
                    return@collect
                }
                cacheSaveJob?.cancel()
                cacheSaveJob = scope.launch {
                    delay(CACHE_SAVE_DEBOUNCE_MILLIS)
                    runCatching { cache.saveSnapshot(userID, state) }
                }
            }
        }
    }

    private suspend fun restoreCachedSnapshot(userID: String) {
        val snapshot = runCatching { cache.loadSnapshot(userID) }.getOrNull()
        contactStore.restoreSnapshot(snapshot ?: ContactState())
    }

    private companion object {
        const val CACHE_SAVE_DEBOUNCE_MILLIS = 500L
    }
}
