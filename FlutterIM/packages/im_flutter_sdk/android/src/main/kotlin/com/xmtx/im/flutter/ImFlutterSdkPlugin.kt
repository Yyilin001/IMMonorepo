package com.xmtx.im.flutter

import android.content.Context
import com.xmtx.im.sharedsdk.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class ImFlutterSdkPlugin : FlutterPlugin {
    private var host: MobileHost? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        host = MobileHost(binding.applicationContext)
        ImHost.setUp(binding.binaryMessenger, host)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ImHost.setUp(binding.binaryMessenger, null)
        val previous = host ?: return
        host = null
        CoroutineScope(Dispatchers.Main.immediate).launch { previous.close() }
    }
}

private class MobileHost(private val context: Context) : ImHost {
    private val mutations = Mutex()
    private var owner: SharedClient? = null
    private val windows = mutableMapOf<String, SharedConversationWindow>()
    private val client: SharedClient get() = owner ?: throw FlutterError("closed")
    private fun String.wire() = replaceFirstChar { it.lowercaseChar() }
    private fun SharedSnapshot.session() = ImSession(state.name.wire(), userID)

    private suspend fun <T> sdk(block: suspend () -> T): T = try {
        block()
    } catch (e: SharedSdkException) {
        throw FlutterError(e.reason.name.wire())
    } catch (e: IllegalArgumentException) {
        throw FlutterError("invalidInput")
    }

    override suspend fun open(accountUrl: String, gatewayHost: String, gatewayPort: Long) = mutations.withLock {
        if (owner != null) throw FlutterError("busy")
        if (gatewayPort !in 1..65535L) throw FlutterError("invalidConfiguration")
        owner = sdk { SharedClient.open(context, SharedEndpoint(accountUrl, gatewayHost, gatewayPort.toInt())) }
    }
    override suspend fun restore() = sdk { client.restore().session() }
    override suspend fun signIn(account: String, password: String) = sdk { client.login(account, password).session() }
    override suspend fun status() = sdk { client.snapshot().session() }
    override suspend fun connect() = sdk { client.connect().session() }
    override suspend fun disconnect() { sdk { client.disconnect() } }

    override suspend fun openWindow(roomId: String?) = mutations.withLock {
        sdk {
            val window = if (roomId == null) client.openConversationList() else {
                client.openConversation(roomId)
                client.openMessageTimeline(roomId)
            }
            windows[window.id] = window
            window.id
        }
    }
    override suspend fun nextUpdate(windowId: String): WindowView = sdk {
        val window = windows[windowId] ?: throw FlutterError("closed")
        val value = window.states().first()
        val messages = value.chat?.messages.orEmpty().map {
            ImMessage(it.id, it.senderID, it.text, it.withdrawn, it.hasMedia, it.readByPeer, it.forwardedFromID != null, if (it.canMutate) it.revision else null, it.replyPreview ?: it.replyToID?.let { "引用消息" }, createdAt = it.createdAt)
        }
        WindowView(value.conversations.map { ImConversation(it.id, it.title, it.preview, it.unread, it.isGroup, it.updatedAt, it.peerID) },
            messages + value.chat?.pending.orEmpty().map {
                ImMessage(it.id, value.userID.orEmpty(), it.text, false, false, false, false, pendingStatus = it.status.name.wire())
            }, value.chat?.hasOlder ?: false, value.chat?.isLatest ?: true)
    }
    override suspend fun directory(nextGroups: Boolean?): DirectoryPage = sdk {
        val directory = when (nextGroups) {
            true -> client.nextGroups()
            false -> client.nextContacts()
            null -> {
                client.contacts(SharedContactScope.Accepted)
                client.firstGroups()
            }
        }.directory ?: throw FlutterError("authenticationRequired")
        val entries = directory.contacts.map { DirectoryEntry(it.userID, it.userID, false) } +
            directory.groups.map { DirectoryEntry(it.id, it.title, true) }
        DirectoryPage(entries, directory.hasMoreContacts, directory.hasMoreGroups)
    }
    override suspend fun changeWindowPage(windowId: String, latest: Boolean) {
        mutations.withLock { sdk {
            val window = windows[windowId] ?: throw FlutterError("closed")
            if (latest) window.reset() else window.nextPage()
        } }
    }
    override suspend fun closeWindow(windowId: String) { sdk { windows.remove(windowId)?.close() } }
    override suspend fun sendText(roomId: String, text: String, replyToMessageId: String?) { mutations.withLock {
        sdk { client.openConversation(roomId); client.sendText(roomId, text, replyToMessageId) }
    } }
    override suspend fun editMessage(roomId: String, messageId: String, revision: Long, text: String) {
        mutations.withLock { sdk { client.editMessage(roomId, messageId, revision, text) } }
    }
    override suspend fun withdrawMessage(roomId: String, messageId: String, revision: Long) {
        mutations.withLock { sdk { client.withdrawMessage(roomId, messageId, revision) } }
    }
    override suspend fun signOut() { mutations.withLock {
        sdk { client.signOut() }
        windows.clear()
    } }
    override suspend fun close() { mutations.withLock {
        sdk { owner?.close() }
        owner = null
        windows.clear()
    } }
}
