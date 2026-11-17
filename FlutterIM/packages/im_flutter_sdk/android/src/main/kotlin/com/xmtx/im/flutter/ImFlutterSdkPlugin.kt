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
    override suspend fun register(account: String, password: String, publicHandle: String, displayName: String) =
        sdk { client.register(account, password, publicHandle, displayName).session() }
    override suspend fun status() = sdk { client.snapshot().session() }
    private fun SharedPrivacy.wire() = ImPrivacy(allowsStrangerMessages, allowsUserAdd, allowsDirectReadReceipts,
        allowsGroupReadReceipts, allowsOnlinePresence, allowsTypingIndicators, blockedUsers)
    override suspend fun favorites(next: Boolean): ImFavorites = mutations.withLock { sdk {
        val page = client.favorites(next).favorites ?: throw FlutterError("authenticationRequired")
        ImFavorites(page.messages.map {
            ImFavoriteMessage(it.id, it.roomID, it.roomTitle, it.senderID, it.text, it.createdAt, it.attachmentNames)
        }, page.hasMore)
    } }
    override suspend fun setFavorite(roomId: String, messageId: String, favorited: Boolean) {
        mutations.withLock { sdk { client.setFavorite(roomId, messageId, favorited) } }
    }
    override suspend fun privacy(): ImPrivacy? = mutations.withLock { sdk { client.privacy().privacy?.wire() } }
    override suspend fun setPrivacy(kind: String, flag1: Boolean?, flag2: Boolean?): ImPrivacy? = mutations.withLock {
        sdk { client.setPrivacy(kind, flag1, flag2).privacy?.wire() }
    }
    override suspend fun deviceSessions(cursor: String?): ImDeviceSessions = sdk {
        val page = client.deviceSessions(cursor).deviceSessions ?: throw FlutterError("operationFailed")
        ImDeviceSessions(page.sessions.map {
            ImDeviceSession(it.deviceID, it.deviceName, it.platform, it.createdAt, it.lastActiveAt, it.isCurrentDevice)
        }, page.nextCursor)
    }
    override suspend fun revokeDevice(deviceId: String?, all: Boolean) {
        mutations.withLock { sdk { client.revokeDevice(deviceId, all) } }
    }
    override suspend fun passwordLifecycle(account: String, action: String, currentPassword: String?, newPassword: String?, recoveryCode: String?) {
        mutations.withLock { sdk { client.passwordLifecycle(account, action, currentPassword, newPassword, recoveryCode) } }
    }
    override suspend fun connect() = sdk { client.connect().session() }
    override suspend fun disconnect() { sdk { client.disconnect() } }

    override suspend fun openWindow(roomId: String?, archived: Boolean) = mutations.withLock {
        sdk {
            val window = if (roomId == null) client.openConversationList(isArchived = archived) else {
                client.openConversation(roomId)
                client.openMessageTimeline(roomId)
            }
            windows[window.id] = window
            window.id
        }
    }
    override suspend fun setConversationState(roomId: String, isPinned: Boolean?, isArchived: Boolean?, muteUntil: Long?) {
        mutations.withLock { sdk { client.setConversationState(roomId, isPinned, isArchived, muteUntil) } }
    }
    override suspend fun nextUpdate(windowId: String): WindowView = sdk {
        val window = windows[windowId] ?: throw FlutterError("closed")
        window.states().first().toWindowView()
    }
    override suspend fun locateMessage(roomId: String, messageId: String): WindowView = mutations.withLock {
        sdk { client.locateMessage(roomId, messageId).toWindowView() }
    }
    private fun SharedSnapshot.toWindowView(): WindowView {
        val value = this
        val messages = value.chat?.messages.orEmpty().map {
            ImMessage(it.id, it.senderID, it.text, it.withdrawn, it.hasMedia, it.attachments.map { a -> Attachment(a.id, a.name, a.contentType, a.bytes) }, it.readByPeer, it.forwardedFromID != null, it.revision, if (it.canMutate) it.revision else null, it.replyPreview ?: it.replyToID?.let { "引用消息" }, createdAt = it.createdAt, replyToId = it.replyToID, mentionSummary = it.mentionSummary,
                entities = it.entities.map { entity -> ImEntity(entity.kind, entity.offset.toLong(), entity.length.toLong(), entity.url) })
        }
        return WindowView(value.conversations.map { ImConversation(it.id, it.title, it.preview, it.unread, it.isGroup, it.isPinned, it.isArchived, it.updatedAt, it.peerID, it.muteUntil) },
            messages + value.chat?.pending.orEmpty().map {
                ImMessage(it.id, value.userID.orEmpty(), it.text, false, false, emptyList(), false, false, pendingStatus = it.preparationStatus ?: it.status.name.wire(), createdAt = it.createdAt,
                    preparedAttachments = it.preparedAttachments, totalAttachments = it.totalAttachments)
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
    private fun SharedProfile.wire(): ImProfile = ImProfile(page, userID, name, handle, alias, aliasRevision, groupNickname,
        groupNicknameRevision, (expiresAtElapsed - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0),
        avatar?.let { android.util.Base64.decode(it, android.util.Base64.DEFAULT) })

    override suspend fun avatar(page: String, userId: String, context: String, roomId: String?): ImAvatarImage? = sdk {
        client.avatar(userId, context, roomId).directory?.profiles
            ?.firstOrNull { it.page == page && it.userID == userId && it.avatar != null }
            ?.let { profile -> ImAvatarImage(android.util.Base64.decode(profile.avatar, android.util.Base64.DEFAULT),
                (profile.expiresAtElapsed - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0)) }
    }
    override suspend fun openAvatarEditor(roomId: String?): ImAvatarEditor? = mutations.withLock { sdk {
        client.openAvatarEditor(roomId).directory?.avatarEditor?.let {
            ImAvatarEditor(it.roomID, it.revision, it.canManage, (it.expiresAtElapsed - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0),
                it.hasAvatar, it.name, it.handle, it.image?.let { encoded -> android.util.Base64.decode(encoded, android.util.Base64.DEFAULT) })
        }
    } }
    override suspend fun changeAvatar(roomId: String?, revision: Long, jpeg: ByteArray?, width: Long?, height: Long?,
                                      displayName: String?, action: String?) {
        mutations.withLock { sdk { client.changeAvatar(roomId, revision,
            jpeg?.let { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) },
            width?.toInt(), height?.toInt(), displayName, action) } }
    }
    override suspend fun profiles(page: String, context: String, roomId: String?, userIds: List<String>): List<ImProfile> = mutations.withLock {
        sdk { client.profiles(page, context, roomId, userIds).directory?.profiles?.map { it.wire() } ?: throw FlutterError("authenticationRequired") }
    }
    override suspend fun openProfile(userId: String, context: String, roomId: String?): List<ImProfile> = mutations.withLock {
        sdk { client.openProfile(userId, context, roomId).directory?.profiles?.map { it.wire() } ?: throw FlutterError("authenticationRequired") }
    }
    override suspend fun saveAlias(userId: String, alias: String?, revision: Long?) {
        mutations.withLock { sdk { client.saveAlias(userId, alias, revision) } }
    }
    override suspend fun clearProfiles(page: String) {
        mutations.withLock { sdk { client.clearProfiles(page) } }
    }
    private suspend fun userId(handle: String): String =
        client.lookupIdentity(handle).directory?.identity?.userID ?: throw FlutterError("identityUnavailable")
    override suspend fun resolveUserId(handle: String): String = mutations.withLock { sdk { userId(handle) } }
    override suspend fun changeMembership(roomId: String, revision: Long, action: String, target: String?, role: String?) {
        val change = SharedGroupAction.entries.firstOrNull { it.wire == action } ?: throw FlutterError("invalidInput")
        val newRole = role?.let { value -> SharedRole.entries.firstOrNull { it.wire == value } ?: throw FlutterError("invalidInput") }
        mutations.withLock { sdk { client.groupAction(roomId, change, revision, targetUserID = target, role = newRole) } }
    }
    override suspend fun groupNickname(roomId: String): ImGroupNickname? = mutations.withLock { sdk {
        client.groupNickname(roomId).directory?.groupNickname?.let { ImGroupNickname(it.roomID, it.name, it.revision) }
    } }
    override suspend fun saveGroupNickname(roomId: String, name: String?, revision: Long?) {
        mutations.withLock { sdk { client.saveGroupNickname(roomId, name, revision) } }
    }
    override suspend fun updateGroupPermissions(roomId: String, revision: Long, role: String, permissions: List<String>) {
        val target = SharedRole.entries.firstOrNull { it.wire == role } ?: throw FlutterError("invalidInput")
        val values = permissions.map { value -> SharedPermission.entries.firstOrNull { it.wire == value } ?: throw FlutterError("invalidInput") }
        mutations.withLock { sdk { client.groupAction(roomId, SharedGroupAction.Permissions, revision, role = target, permissions = values) } }
    }
    override suspend fun moderateMemberRemoval(roomId: String, userId: String, revision: Long) {
        mutations.withLock { sdk { client.moderateMemberRemoval(roomId, userId, revision) } }
    }
    override suspend fun updateAnnouncement(roomId: String, revision: Long, text: String) {
        mutations.withLock { sdk { client.groupAction(roomId, SharedGroupAction.Announcement, revision, text = text) } }
    }
    override suspend fun groupMembers(roomId: String, next: Boolean): GroupPage = mutations.withLock { sdk {
        val snapshot = if (next) client.nextGroupMembers(roomId) else client.openGroup(roomId)
        val group = snapshot.directory?.group?.takeIf { it.roomID == roomId } ?: throw FlutterError("operationFailed")
        GroupPage(group.announcement, group.announcementRevision.takeIf { SharedPermission.ManageAnnouncements in group.permissions }, group.revision, group.actorRole.wire, group.permissions.map { it.wire }, group.members.map { GroupMember(it.userID, it.role.wire) },
            group.policies.map { ImGroupPolicy(it.role.wire, it.permissions.map { permission -> permission.wire }, it.revision) }, group.policiesReady, group.hasMore)
    } }
    private fun SharedCommunity.wire(): ImCommunity = ImCommunity(roomID,
        invites.map { ImInvite(it.id, it.url, it.expires, it.used.toLong(), it.maximum.toLong()) },
        requests.map { ImJoinRequest(it.id, it.userID, it.note, it.state) }, hasMore,
        preview?.let { ImInvitePreview(it.roomID, it.title, it.requestID, it.state, it.member, it.canSubmit, it.canCancel) },
        failure?.name?.wire())

    private fun SharedSnapshot.community(): ImCommunity =
        directory?.community?.wire() ?: throw FlutterError("authenticationRequired")

    override suspend fun invitations(roomId: String): ImCommunity = mutations.withLock { sdk { client.invitations(roomId).community() } }
    override suspend fun nextInvitations(roomId: String): ImCommunity = mutations.withLock { sdk { client.nextInvitations(roomId).community() } }
    override suspend fun previewInvite(text: String): ImCommunity = mutations.withLock { sdk { client.previewInvite(text).community() } }
    override suspend fun refreshInvite(): ImCommunity = mutations.withLock { sdk { client.refreshInvite().community() } }
    override suspend fun inviteAction(roomId: String, revision: Long, action: String, intentId: String?, note: String?) {
        val command = SharedInviteAction.entries.firstOrNull { it.wire == action } ?: throw FlutterError("invalidInput")
        mutations.withLock { sdk { client.inviteAction(roomId, command, revision = revision, id = intentId, note = note) } }
    }
    override suspend fun submitJoin(note: String) {
        mutations.withLock { sdk { client.inviteAction("", SharedInviteAction.Submit, note = note) } }
    }
    override suspend fun cancelJoin(roomId: String) {
        mutations.withLock { sdk { client.inviteAction(roomId, SharedInviteAction.Cancel) } }
    }
    override suspend fun muteMember(roomId: String, userId: String, revision: Long) {
        mutations.withLock { sdk { client.muteMember(roomId, userId, revision) } }
    }
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
    override suspend fun searchMessages(roomId: String?, query: String, next: Boolean): SearchPage = mutations.withLock {
        sdk {
            val snapshot = if (next) client.nextSearch() else client.searchMessages(query, roomId)
            val page = snapshot.messaging?.search ?: throw FlutterError("invalidInput")
            if (page.roomID != roomId || page.query != query) throw FlutterError("invalidInput")
            SearchPage(page.status, page.hits.map { SearchHit(it.id, it.roomID, it.text) }, page.hasNext)
        }
    }
    override suspend fun clearMessageSearch() { mutations.withLock { sdk { client.clearMessaging() } } }
    override suspend fun messageReaders(roomId: String, messageId: String, next: Boolean): ImReaders = mutations.withLock { sdk {
        val readers = client.messageReaders(roomId, messageId, next).messaging?.readers ?: throw FlutterError("operationFailed")
        ImReaders(readers.roomID, readers.messageID, readers.users, readers.hasNext,
            (readers.expiresAtElapsed - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0))
    } }
    override suspend fun recoverSend(intentId: String, resend: Boolean) {
        mutations.withLock { sdk { if (resend) client.resendUnsent(intentId) else client.retrySend(intentId) } }
    }
    override suspend fun sendText(roomId: String, text: String, replyToMessageId: String?, mentions: List<String>?) { mutations.withLock {
        sdk { client.openConversation(roomId); client.sendText(roomId, text, replyToMessageId, mentions) }
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
