package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthResponseBody
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.DeviceMetadataPayload
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.auth.SessionSnapshot
import com.xmtx.imclientkit.features.contacts.ContactRequestBox
import com.xmtx.imclientkit.features.contacts.ContactRequestResponseBody
import com.xmtx.imclientkit.features.contacts.ContactResponseBody
import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.features.im.IMConversationMemberPageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationMemberRole
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationMessagesSinceResponseBody
import com.xmtx.imclientkit.features.im.IMMessageStreamResponseBody
import com.xmtx.imclientkit.features.im.IMConversationReadResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.networking.APIError
import com.xmtx.imclientkit.networking.AuthorizedRequestExecutor
import com.xmtx.imclientkit.networking.HTTPExecutor
import com.xmtx.imclientkit.networking.JsonConfiguration
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPClient
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientError
import com.xmtx.imclientkit.networking.imtcp.IMTCPConnection
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransport
import com.xmtx.imclientkit.networking.imtcp.SocketIMTCPTransport
import com.xmtx.imclientkit.persistence.TokenSnapshot
import com.xmtx.imclientkit.persistence.TokenStore
import com.xmtx.imclientkit.persistence.UserSessionCache
import com.xmtx.imclientkit.services.AuthAPI
import com.xmtx.imclientkit.services.EmptyResponse
import com.xmtx.imclientkit.services.IMAPI
import com.xmtx.imclientkit.services.UserAPI
import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json

class SessionClient internal constructor(
    network: NetworkEnvironment,
    private val tokenStore: TokenStore,
    private val userCache: UserSessionCache,
    httpClient: HttpClient = network.makeHttpClient(),
    private val json: Json = JsonConfiguration.default,
) {
    constructor(
        network: NetworkEnvironment,
        tokenStore: TokenStore,
        userCache: UserSessionCache,
    ) : this(
        network = network,
        tokenStore = tokenStore,
        userCache = userCache,
        httpClient = network.makeHttpClient(),
        json = JsonConfiguration.default,
    )

    private val authAPI = AuthAPI(json)
    private val userAPI = UserAPI(json)
    private val imAPI = IMAPI(json)
    private val httpExecutor = HTTPExecutor(httpClient, network, json)
    private val authorizedExecutor = AuthorizedRequestExecutor(
        httpExecutor = httpExecutor,
        tokenStore = tokenStore,
        refreshAccessToken = { refreshAccessToken() },
        clearSession = { clearSession() },
    )

    suspend fun login(
        email: String,
        password: String,
        device: DeviceMetadataPayload? = DeviceMetadataPayload(),
    ): AuthUser {
        val response = httpExecutor.execute<AuthResponseBody>(authAPI.login(email, password, device))
        persistAuth(response)
        return response.user
    }

    suspend fun register(
        email: String,
        password: String,
        device: DeviceMetadataPayload? = DeviceMetadataPayload(),
    ): AuthUser {
        val response = httpExecutor.execute<AuthResponseBody>(authAPI.register(email, password, device))
        persistAuth(response)
        return response.user
    }

    suspend fun restoreSession(): RestoreResult {
        val user = userCache.load()
        val tokens = tokenStore.load()
        if (user == null || tokens == null) {
            clearSession()
            return RestoreResult.SignedOut()
        }

        return try {
            val freshUser = fetchMe()
            RestoreResult.Authenticated(freshUser)
        } catch (_: APIError.AuthenticationExpired) {
            clearSession()
            RestoreResult.SignedOut("Session expired.")
        } catch (_: Throwable) {
            RestoreResult.Authenticated(user)
        }
    }

    suspend fun fetchMe(): AuthUser {
        val user = authorizedExecutor.execute<AuthUser>(userAPI.me())
        userCache.save(user)
        return user
    }

    suspend fun fetchSessions(): List<SessionSnapshot> =
        authorizedExecutor.execute(authAPI.sessions())

    suspend fun fetchContacts(): List<ContactResponseBody> =
        authorizedExecutor.execute(userAPI.contacts())

    suspend fun addContact(email: String, remark: String? = null): ContactResponseBody =
        authorizedExecutor.execute(userAPI.addContact(email, remark))

    suspend fun updateContact(contactUserID: String, remark: String?): ContactResponseBody =
        authorizedExecutor.execute(userAPI.updateContact(contactUserID, remark))

    suspend fun deleteContact(contactUserID: String): EmptyResponse =
        authorizedExecutor.execute(userAPI.deleteContact(contactUserID))

    suspend fun fetchContactRequests(box: ContactRequestBox = ContactRequestBox.All): List<ContactRequestResponseBody> =
        authorizedExecutor.execute(userAPI.contactRequests(box))

    suspend fun sendContactRequest(
        email: String,
        message: String? = null,
        remark: String? = null,
    ): ContactRequestResponseBody =
        authorizedExecutor.execute(userAPI.sendContactRequest(email, message, remark))

    suspend fun acceptContactRequest(requestID: String, remark: String? = null): ContactResponseBody =
        authorizedExecutor.execute(userAPI.acceptContactRequest(requestID, remark))

    suspend fun declineContactRequest(requestID: String): ContactRequestResponseBody =
        authorizedExecutor.execute(userAPI.declineContactRequest(requestID))

    suspend fun cancelContactRequest(requestID: String): ContactRequestResponseBody =
        authorizedExecutor.execute(userAPI.cancelContactRequest(requestID))

    suspend fun fetchIMConversationSummaries(
        cursor: String? = null,
        limit: Int? = null,
        kind: IMConversationKind? = null,
    ): IMConversationSummaryPageResponseBody =
        authorizedExecutor.execute(imAPI.conversations(cursor, limit, kind))

    suspend fun createIMConversation(
        kind: IMConversationKind,
        title: String? = null,
        memberEmails: List<String>,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.createConversation(kind, title, memberEmails))

    suspend fun fetchIMConversationMembers(
        conversationID: String,
        cursor: String? = null,
        limit: Int? = null,
        query: String? = null,
    ): IMConversationMemberPageResponseBody =
        authorizedExecutor.execute(imAPI.members(conversationID, cursor, limit, query))

    suspend fun addIMConversationMembers(
        conversationID: String,
        memberEmails: List<String>,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.addMembers(conversationID, memberEmails))

    suspend fun removeIMConversationMember(
        conversationID: String,
        memberUserID: String,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.removeMember(conversationID, memberUserID))

    suspend fun updateIMConversationMemberRole(
        conversationID: String,
        memberUserID: String,
        role: IMConversationMemberRole,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.updateMemberRole(conversationID, memberUserID, role))

    suspend fun updateIMConversationTitle(conversationID: String, title: String): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.updateTitle(conversationID, title))

    suspend fun updateIMConversationPreferences(
        conversationID: String,
        isPinned: Boolean? = null,
        isMuted: Boolean? = null,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.updatePreferences(conversationID, isPinned, isMuted))

    suspend fun updateIMConversationMetadata(
        conversationID: String,
        title: String? = null,
        notice: String? = null,
        avatarPreset: String? = null,
        muteAll: Boolean? = null,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.updateMetadata(conversationID, title, notice, avatarPreset, muteAll))

    suspend fun updateIMMyMemberProfile(
        conversationID: String,
        memberNickname: String?,
    ): IMConversationSummaryResponseBody =
        authorizedExecutor.execute(imAPI.updateMyMemberProfile(conversationID, memberNickname))

    suspend fun fetchIMMessages(
        conversationID: String,
        beforeSequence: ULong? = null,
        limit: Int? = null,
    ): List<IMConversationMessageResponseBody> =
        authorizedExecutor.execute(imAPI.messages(conversationID, beforeSequence, limit))

    suspend fun fetchIMMessagesSince(
        conversationID: String,
        afterSequence: ULong,
        limit: Int? = null,
    ): IMConversationMessagesSinceResponseBody =
        authorizedExecutor.execute(imAPI.messagesSince(conversationID, afterSequence, limit))

    suspend fun startAIMessageStream(
        conversationID: String,
        prompt: String,
    ): IMMessageStreamResponseBody =
        authorizedExecutor.execute(imAPI.startAIMessageStream(conversationID, prompt))

    suspend fun cancelMessageStream(
        conversationID: String,
        messageID: String,
    ): IMMessageStreamResponseBody =
        authorizedExecutor.execute(imAPI.cancelMessageStream(conversationID, messageID))

    suspend fun fetchMessageStreamSnapshot(
        conversationID: String,
        messageID: String,
    ): IMMessageStreamResponseBody =
        authorizedExecutor.execute(imAPI.messageStreamSnapshot(conversationID, messageID))

    suspend fun markIMConversationRead(
        conversationID: String,
        readSequence: ULong,
    ): IMConversationReadResponseBody =
        authorizedExecutor.execute(imAPI.markRead(conversationID, readSequence))

    suspend fun clearIMConversationForSelf(conversationID: String): EmptyResponse =
        authorizedExecutor.execute(imAPI.clearConversationForSelf(conversationID))

    suspend fun deleteIMConversationForSelf(conversationID: String): EmptyResponse =
        authorizedExecutor.execute(imAPI.deleteConversationForSelf(conversationID))

    suspend fun leaveIMConversation(conversationID: String): EmptyResponse =
        authorizedExecutor.execute(imAPI.leaveConversation(conversationID))

    suspend fun openIMConnection(
        configuration: IMTCPClientConfiguration,
        transport: IMTCPTransport = SocketIMTCPTransport(),
    ): IMTCPConnection =
        openIMConnection(configuration, transport, allowRefreshRetry = true)

    suspend fun clearSession() {
        tokenStore.clear()
        userCache.clear()
    }

    private suspend fun refreshAccessToken(): String {
        val refreshToken = tokenStore.load()?.refreshToken ?: throw APIError.AuthenticationExpired
        val response = httpExecutor.execute<AuthResponseBody>(authAPI.refresh(refreshToken))
        persistAuth(response)
        return response.accessToken
    }

    private suspend fun validAccessToken(): String =
        tokenStore.load()?.accessToken ?: refreshAccessToken()

    private suspend fun openIMConnection(
        configuration: IMTCPClientConfiguration,
        transport: IMTCPTransport,
        allowRefreshRetry: Boolean,
    ): IMTCPConnection {
        val client = IMTCPClient(
            configuration = configuration,
            transport = transport,
            accessTokenProvider = { validAccessToken() },
        )
        return try {
            client.connect()
        } catch (error: IMTCPClientError.AuthRejected) {
            if (!allowRefreshRetry) throw error
            refreshAccessToken()
            openIMConnection(configuration, transport, allowRefreshRetry = false)
        }
    }

    private suspend fun persistAuth(response: AuthResponseBody) {
        tokenStore.save(
            TokenSnapshot(
                accessToken = response.accessToken,
                refreshToken = response.refreshToken,
            ),
        )
        userCache.save(response.user)
    }
}
