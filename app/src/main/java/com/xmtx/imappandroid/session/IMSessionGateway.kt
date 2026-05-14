package com.xmtx.imappandroid.session

import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.DeviceMetadataPayload
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import com.xmtx.imclientkit.features.im.IMRuntimeController
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

interface IMSessionGateway {
    val conversationState: StateFlow<ConversationListState>
    val sessionInvalidations: SharedFlow<String>
    suspend fun restoreSession(): RestoreResult
    suspend fun login(email: String, password: String): AuthUser
    suspend fun register(email: String, password: String): AuthUser
    suspend fun clearSession()
    fun startIMRuntime(userID: String)
    fun stopIMRuntime()
    fun reloadConversations()
    fun openConversation(conversationID: String)
    fun sendText(text: String, conversationID: String)
    suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody
    suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody>
}

class IMClientKitGateway(
    private val sessionClient: SessionClient,
    private val runtimeController: IMRuntimeController,
    private val conversationStore: IMConversationStore,
) : IMSessionGateway {
    override val conversationState: StateFlow<ConversationListState> = conversationStore.state
    override val sessionInvalidations: SharedFlow<String> = runtimeController.sessionInvalidations

    override suspend fun restoreSession(): RestoreResult = sessionClient.restoreSession()

    override suspend fun login(email: String, password: String): AuthUser =
        sessionClient.login(
            email = email,
            password = password,
            device = DeviceMetadataPayload(platform = "android"),
        )

    override suspend fun register(email: String, password: String): AuthUser =
        sessionClient.register(
            email = email,
            password = password,
            device = DeviceMetadataPayload(platform = "android"),
        )

    override suspend fun clearSession() {
        runtimeController.stop()
        sessionClient.clearSession()
    }

    override fun startIMRuntime(userID: String) {
        runtimeController.start(userID)
    }

    override fun stopIMRuntime() {
        runtimeController.stop()
    }

    override fun reloadConversations() {
        runtimeController.reloadConversations()
    }

    override fun openConversation(conversationID: String) {
        runtimeController.openConversation(conversationID)
    }

    override fun sendText(text: String, conversationID: String) {
        runtimeController.sendText(text, conversationID)
    }

    override suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody =
        sessionClient.fetchIMConversationSummaries(limit = 50)

    override suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody> =
        sessionClient.fetchIMMessages(conversationID = conversationID, limit = 50)
}
