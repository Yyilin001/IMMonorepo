package com.xmtx.imappandroid.di

import android.content.Context
import com.xmtx.imappandroid.session.IMClientKitGateway
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMRuntimeController
import com.xmtx.imclientkit.networking.NetworkEnvironment
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.persistence.DataStoreTokenStore
import com.xmtx.imclientkit.persistence.DataStoreUserSessionCache

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
    private val runtimeController = IMRuntimeController(
        sessionClient = sessionClient,
        conversationStore = conversationStore,
        configuration = IMTCPClientConfiguration(
            host = network.imTcpHost,
            port = network.imTcpPort,
            platform = "android",
        ),
    )

    val sessionGateway: IMSessionGateway = IMClientKitGateway(
        sessionClient = sessionClient,
        runtimeController = runtimeController,
        conversationStore = conversationStore,
    )
}
