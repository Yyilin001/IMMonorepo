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
            ImMessage(it.id, it.senderID, it.text, it.withdrawn, it.hasMedia, it.attachments.map { a -> Attachment(a.id, a.name, a.contentType, a.bytes) }, it.readByPeer, it.forwardedFromID != null, it.revision, if (it.canMutate) it.revision else null, it.replyPreview ?: it.replyToID?.let { "引用消息" }, createdAt = it.createdAt)
        }
        WindowView(value.conversations.map { ImConversation(it.id, it.title, it.preview, it.unread, it.isGroup, it.updatedAt, it.peerID) },
            messages + value.chat?.pending.orEmpty().map {
                ImMessage(it.id, value.userID.orEmpty(), it.text, false, false, emptyList(), false, false, pendingStatus = it.status.name.wire())
            }, value.chat?.hasOlder ?: false, value.chat?.isLatest ?: true)
    }
    override suspend fun directory(nextGroups: Boolean?, scope: String): DirectoryPage = sdk {
        val directory = when (nextGroups) {
            true -> client.nextGroups()
            false -> client.nextContacts()
            null -> {
                client.contacts(SharedContactScope.entries.firstOrNull { it.wire == scope } ?: throw FlutterError("invalidInput"))
                client.firstGroups()
            }
        }.directory ?: throw FlutterError("authenticationRequired")
        val entries = directory.contacts.map { DirectoryEntry(it.userID, it.userID, false) } +
            directory.groups.map { DirectoryEntry(it.id, it.title, true) }
        DirectoryPage(entries, directory.hasMoreContacts, directory.hasMoreGroups)
    }
    private suspend fun userId(handle: String): String =
        client.lookupIdentity(handle).directory?.identity?.userID ?: throw FlutterError("identityUnavailable")
    override suspend fun resolveUserId(handle: String): String = mutations.withLock { sdk { userId(handle) } }
    override suspend fun changeMembership(roomId: String, revision: Long, action: String, target: String?, role: String?) {
        val change = SharedGroupAction.entries.firstOrNull { it.wire == action } ?: throw FlutterError("invalidInput")
        val newRole = role?.let { value -> SharedRole.entries.firstOrNull { it.wire == value } ?: throw FlutterError("invalidInput") }
        mutations.withLock { sdk { client.groupAction(roomId, change, revision, targetUserID = target, role = newRole) } }
    }
    override suspend fun updateAnnouncement(roomId: String, revision: Long, text: String) {
        mutations.withLock { sdk { client.groupAction(roomId, SharedGroupAction.Announcement, revision, text = text) } }
    }
    override suspend fun groupMembers(roomId: String, next: Boolean): GroupPage = mutations.withLock { sdk {
        val snapshot = if (next) client.nextGroupMembers(roomId) else client.openGroup(roomId)
        val group = snapshot.directory?.group?.takeIf { it.roomID == roomId } ?: throw FlutterError("operationFailed")
        GroupPage(group.announcement, group.announcementRevision.takeIf { SharedPermission.ManageAnnouncements in group.permissions }, group.revision, group.actorRole.wire, group.permissions.map { it.wire }, group.members.map { GroupMember(it.userID, it.role.wire) }, group.hasMore)
    } }
    override suspend fun createGroup(title: String, members: List<String>) {
        mutations.withLock { sdk { client.createGroup(title, members) } }
    }
    override suspend fun requestContact(handle: String) {
        mutations.withLock { sdk {
            client.socialAction(userId(handle), SharedSocialAction.Request)
        } }
    }
    override suspend fun socialAction(userId: String, action: String) {
        mutations.withLock { sdk { client.socialAction(userId, SharedSocialAction.entries.firstOrNull { it.wire == action } ?: throw FlutterError("invalidInput")) } }
    }
    override suspend fun changeWindowPage(windowId: String, latest: Boolean) {
        mutations.withLock { sdk {
            val window = windows[windowId] ?: throw FlutterError("closed")
            if (latest) window.reset() else window.nextPage()
        } }
    }
    override suspend fun closeWindow(windowId: String) { sdk { windows.remove(windowId)?.close() } }
    override suspend fun cancelPendingSend(intentId: String) {
        mutations.withLock { sdk { client.cancelAttachmentSend(intentId) } }
    }
    override suspend fun recoverSend(intentId: String, resend: Boolean) {
        mutations.withLock { sdk { if (resend) client.resendUnsent(intentId) else client.retrySend(intentId) } }
    }
    override suspend fun sendText(roomId: String, text: String, replyToMessageId: String?) { mutations.withLock {
        sdk { client.openConversation(roomId); client.sendText(roomId, text, replyToMessageId) }
    } }
    override suspend fun sendAttachment(roomId: String, path: String, name: String, contentType: String, text: String) {
        mutations.withLock { sdk {
            val asset = withContext(Dispatchers.IO) {
                java.io.File(path).inputStream().use { input ->
                    client.importAttachment(roomId, name, contentType, input).resource?.draft?.id
                }
            } ?: throw FlutterError("operationFailed")
            try { client.sendAttachment(roomId, asset, text) }
            catch (failure: Exception) {
                withContext(NonCancellable) { runCatching { client.clearResources() } }
                throw failure
            }
        } }
    }
    override suspend fun transfers(): List<Transfer> = sdk {
        val view = client.snapshot().resource ?: throw FlutterError("authenticationRequired")
        view.transfers.map { Transfer(it.id, it.name, it.kind, it.phase, it.bytes, it.confirmed, it.actions) }
    }
    override suspend fun transferAction(id: String, action: String) {
        val command = SharedTransferAction.entries.firstOrNull { it.wire == action } ?: throw FlutterError("invalidInput")
        mutations.withLock { sdk { client.transferAction(id, command) } }
    }
    override suspend fun previewAttachment(roomId: String, messageId: String, mediaId: String): AttachmentPreview = mutations.withLock { sdk {
        client.openResource(roomId, messageId, mediaId)
        val resource = client.previewResource().resource ?: throw FlutterError("previewUnavailable")
        val encoded = resource.image
        val remaining = resource.expiresAtElapsed - android.os.SystemClock.elapsedRealtime()
        if (encoded == null || remaining <= 0 || resource.roomID != roomId ||
            resource.messageID != messageId || resource.selected?.id != mediaId) throw FlutterError("previewUnavailable")
        AttachmentPreview(android.util.Base64.decode(encoded, android.util.Base64.DEFAULT), remaining)
    } }
    override suspend fun exportAttachment(roomId: String, messageId: String, mediaId: String, destination: String) {
        mutations.withLock { sdk {
            val selected = client.openResource(roomId, messageId, mediaId).resource?.selected
            if (selected?.id != mediaId) throw FlutterError("invalidInput")
            withContext(Dispatchers.IO) {
                val path = java.io.File(destination).toPath()
                val output = java.nio.file.Files.newOutputStream(path, java.nio.file.StandardOpenOption.CREATE_NEW, java.nio.file.StandardOpenOption.WRITE)
                try {
                    output.use { client.exportResource(it) }
                    if (java.nio.file.Files.size(path) != selected.bytes) throw FlutterError("operationFailed")
                } catch (error: Exception) {
                    java.nio.file.Files.deleteIfExists(path)
                    throw error
                }
            }
        } }
    }
    override suspend fun downloadAttachment(roomId: String, messageId: String, mediaId: String) {
        mutations.withLock { sdk {
            client.openResource(roomId, messageId, mediaId)
            client.downloadResource()
        } }
    }
    override suspend fun forwardMessage(roomId: String, messageId: String, revision: Long, targetRoomIds: List<String>) {
        mutations.withLock { sdk { client.forwardMessage(roomId, messageId, revision, targetRoomIds) } }
    }
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
