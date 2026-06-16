package com.xmtx.imappandroid.di

import android.content.Context
import com.xmtx.imappandroid.BuildConfig
import com.xmtx.imappandroid.session.IMClientKitGateway
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.features.contacts.ContactRuntimeController
import com.xmtx.imclientkit.features.contacts.ContactStateStore
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMRuntimeController
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.persistence.DataStoreDeviceIdentityStore
import com.xmtx.imclientkit.persistence.DataStoreUserSessionCache
import com.xmtx.imclientkit.persistence.EncryptedTokenStore
import com.xmtx.imclientkit.persistence.imcache.IMCacheDatabase
import com.xmtx.imclientkit.persistence.imcache.RoomIMConversationCache
import com.xmtx.imclientkit.persistence.imcache.RoomContactStateCache
import kotlinx.coroutines.runBlocking

class AppContainer(context: Context) {
    private val appContext = context.applicationContext
    private val deviceIdentityStore = DataStoreDeviceIdentityStore(appContext)
    private val deviceID = runBlocking { deviceIdentityStore.currentDeviceID() }

    val network = networkEnvironmentFromBuildConfig()
    private val tokenStore = EncryptedTokenStore(appContext)

    private val sessionClient = SessionClient(
        network = network,
        tokenStore = tokenStore,
        userCache = DataStoreUserSessionCache(appContext),
    )

    private val conversationStore = IMConversationStore()
    private val contactStore = ContactStateStore()
    private val cacheDatabase = IMCacheDatabase.create(appContext)
    private val conversationCache = RoomIMConversationCache.create(cacheDatabase)
    private val contactCache = RoomContactStateCache.create(cacheDatabase)
    private val contactRuntimeController = ContactRuntimeController(
        sessionClient = sessionClient,
        contactStore = contactStore,
        cache = contactCache,
    )
    private val runtimeController = IMRuntimeController(
        sessionClient = sessionClient,
        conversationStore = conversationStore,
        configuration = IMTCPClientConfiguration(
            host = network.imTcpHost,
            port = network.imTcpPort,
            deviceID = deviceID,
            platform = "android",
        ),
        conversationCache = conversationCache,
        contactEventHandler = contactRuntimeController::handleContactEvent,
    )

    val sessionGateway: IMSessionGateway = IMClientKitGateway(
        sessionClient = sessionClient,
        runtimeController = runtimeController,
        conversationStore = conversationStore,
        contactRuntimeController = contactRuntimeController,
        contactStore = contactStore,
        deviceID = deviceID,
    )

    private fun networkEnvironmentFromBuildConfig(): NetworkEnvironment {
        val environment = NetworkEnvironment(
            apiBaseUrl = BuildConfig.IM_API_BASE_URL,
            imTcpHost = BuildConfig.IM_TCP_HOST,
            imTcpPort = BuildConfig.IM_TCP_PORT,
        )
        if (!BuildConfig.DEBUG) {
            require(environment.apiBaseUrl.startsWith("https://")) {
                "Release builds require an HTTPS IM_API_BASE_URL."
            }
            require(BuildConfig.IM_TCP_REQUIRES_TLS_TERMINATION || isPrivateOrLoopbackTCPHost(environment.imTcpHost)) {
                "Release builds require IM_TCP_REQUIRES_TLS_TERMINATION=true for public TCP hosts."
            }
        }
        return environment
    }

    private fun isPrivateOrLoopbackTCPHost(host: String): Boolean {
        val normalized = host.trim().lowercase()
        if (normalized == "localhost" || normalized == "::1" || normalized.startsWith("127.")) return true
        if (normalized.startsWith("10.") || normalized.startsWith("192.168.")) return true
        val parts = normalized.split(".").mapNotNull { it.toIntOrNull() }
        return parts.size == 4 && parts[0] == 172 && parts[1] in 16..31
    }
}
