package com.xmtx.imappandroid.session

import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.DeviceMetadataPayload
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody

interface IMSessionGateway {
    suspend fun restoreSession(): RestoreResult
    suspend fun login(email: String, password: String): AuthUser
    suspend fun register(email: String, password: String): AuthUser
    suspend fun clearSession()
    suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody
    suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody>
}

class IMClientKitGateway(
    private val sessionClient: SessionClient,
) : IMSessionGateway {
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
        sessionClient.clearSession()
    }

    override suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody =
        sessionClient.fetchIMConversationSummaries(limit = 50)

    override suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody> =
        sessionClient.fetchIMMessages(conversationID = conversationID, limit = 50)
}
