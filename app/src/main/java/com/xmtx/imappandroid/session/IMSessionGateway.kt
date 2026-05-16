package com.xmtx.imappandroid.session

import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.DeviceMetadataPayload
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.contacts.ContactRuntimeController
import com.xmtx.imclientkit.features.contacts.ContactState
import com.xmtx.imclientkit.features.contacts.ContactStateStore
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import com.xmtx.imclientkit.features.im.IMRuntimeController
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

interface IMSessionGateway {
    val conversationState: StateFlow<ConversationListState>
    val contactState: StateFlow<ContactState>
    val sessionInvalidations: SharedFlow<String>
    suspend fun restoreSession(): RestoreResult
    suspend fun login(email: String, password: String): AuthUser
    suspend fun register(email: String, password: String): AuthUser
    suspend fun clearSession()
    fun startIMRuntime(userID: String)
    fun stopIMRuntime()
    fun reloadConversations()
    fun reloadContacts()
    fun openConversation(conversationID: String)
    fun sendText(text: String, conversationID: String)
    fun addContact(email: String, remark: String?)
    fun sendContactRequest(email: String, message: String?, remark: String?)
    fun acceptContactRequest(requestID: String, remark: String?)
    fun declineContactRequest(requestID: String)
    fun createConversation(kind: IMConversationKind, title: String?, memberEmails: List<String>)
    fun loadConversationMembers(conversationID: String)
    fun addConversationMembers(conversationID: String, memberEmails: List<String>)
    fun updateConversationTitle(conversationID: String, title: String)
    fun updateConversationPreferences(conversationID: String, isPinned: Boolean?, isMuted: Boolean?)
    fun clearConversation(conversationID: String)
    fun deleteConversation(conversationID: String)
    fun leaveConversation(conversationID: String)
    suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody
    suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody>
}

class IMClientKitGateway(
    private val sessionClient: SessionClient,
    private val runtimeController: IMRuntimeController,
    private val conversationStore: IMConversationStore,
    private val contactRuntimeController: ContactRuntimeController,
    private val contactStore: ContactStateStore,
    private val deviceID: String,
) : IMSessionGateway {
    override val conversationState: StateFlow<ConversationListState> = conversationStore.state
    override val contactState: StateFlow<ContactState> = contactStore.state
    override val sessionInvalidations: SharedFlow<String> = runtimeController.sessionInvalidations

    override suspend fun restoreSession(): RestoreResult = sessionClient.restoreSession()

    override suspend fun login(email: String, password: String): AuthUser =
        sessionClient.login(
            email = email,
            password = password,
            device = DeviceMetadataPayload(deviceID = deviceID, platform = "android"),
        )

    override suspend fun register(email: String, password: String): AuthUser =
        sessionClient.register(
            email = email,
            password = password,
            device = DeviceMetadataPayload(deviceID = deviceID, platform = "android"),
        )

    override suspend fun clearSession() {
        runtimeController.stop()
        contactRuntimeController.stop()
        sessionClient.clearSession()
    }

    override fun startIMRuntime(userID: String) {
        runtimeController.start(userID)
        contactRuntimeController.start(userID)
    }

    override fun stopIMRuntime() {
        runtimeController.stop()
        contactRuntimeController.stop()
    }

    override fun reloadConversations() {
        runtimeController.reloadConversations()
    }

    override fun reloadContacts() {
        contactRuntimeController.refreshAll()
    }

    override fun openConversation(conversationID: String) {
        runtimeController.openConversation(conversationID)
    }

    override fun sendText(text: String, conversationID: String) {
        runtimeController.sendText(text, conversationID)
    }

    override fun addContact(email: String, remark: String?) {
        contactRuntimeController.addContact(email, remark)
    }

    override fun sendContactRequest(email: String, message: String?, remark: String?) {
        contactRuntimeController.sendContactRequest(email, message, remark)
    }

    override fun acceptContactRequest(requestID: String, remark: String?) {
        contactRuntimeController.acceptContactRequest(requestID, remark)
    }

    override fun declineContactRequest(requestID: String) {
        contactRuntimeController.declineContactRequest(requestID)
    }

    override fun createConversation(kind: IMConversationKind, title: String?, memberEmails: List<String>) {
        runtimeController.createConversation(kind, title, memberEmails)
    }

    override fun loadConversationMembers(conversationID: String) {
        runtimeController.loadMembers(conversationID)
    }

    override fun addConversationMembers(conversationID: String, memberEmails: List<String>) {
        runtimeController.addMembers(conversationID, memberEmails)
    }

    override fun updateConversationTitle(conversationID: String, title: String) {
        runtimeController.updateTitle(conversationID, title)
    }

    override fun updateConversationPreferences(conversationID: String, isPinned: Boolean?, isMuted: Boolean?) {
        runtimeController.updatePreferences(conversationID, isPinned, isMuted)
    }

    override fun clearConversation(conversationID: String) {
        runtimeController.clearConversation(conversationID)
    }

    override fun deleteConversation(conversationID: String) {
        runtimeController.deleteConversation(conversationID)
    }

    override fun leaveConversation(conversationID: String) {
        runtimeController.leaveConversation(conversationID)
    }

    override suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody =
        sessionClient.fetchIMConversationSummaries(limit = 50)

    override suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody> =
        sessionClient.fetchIMMessages(conversationID = conversationID, limit = 50)
}
