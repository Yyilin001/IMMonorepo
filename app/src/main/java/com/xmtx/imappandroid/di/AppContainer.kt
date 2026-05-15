package com.xmtx.imappandroid.di

import android.content.Context
import com.xmtx.imappandroid.session.IMClientKitGateway
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.features.contacts.ContactRuntimeController
import com.xmtx.imclientkit.features.contacts.ContactStateStore
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMRuntimeController
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.persistence.DataStoreTokenStore
import com.xmtx.imclientkit.persistence.DataStoreUserSessionCache
import com.xmtx.imclientkit.persistence.imcache.IMCacheDatabase
import com.xmtx.imclientkit.persistence.imcache.RoomIMConversationCache
import com.xmtx.imclientkit.persistence.imcache.RoomContactStateCache

class AppContainer(context: Context) {
    private val appContext = context.applicationContext

    val network = NetworkEnvironment(
        apiBaseUrl = "http://10.0.2.2:8080",
        imTcpHost = "10.0.2.2",
        imTcpPort = 9000,
    )

    private val sessionClient = SessionClient(
        network = network,
        tokenStore = DataStoreTokenStore(appContext),
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
    )
}
