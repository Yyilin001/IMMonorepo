package com.xmtx.imclientkit

import com.xmtx.imclientkit.auth.AuthResponseBody
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.DeviceMetadataPayload
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.auth.SessionSnapshot
import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationMessagesSinceResponseBody
import com.xmtx.imclientkit.features.im.IMConversationReadResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
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
    private val userAPI = UserAPI()
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

    suspend fun fetchIMConversationSummaries(
        cursor: String? = null,
        limit: Int? = null,
        kind: IMConversationKind? = null,
    ): IMConversationSummaryPageResponseBody =
        authorizedExecutor.execute(imAPI.conversations(cursor, limit, kind))

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

    suspend fun markIMConversationRead(
        conversationID: String,
        readSequence: ULong,
    ): IMConversationReadResponseBody =
        authorizedExecutor.execute(imAPI.markRead(conversationID, readSequence))

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
