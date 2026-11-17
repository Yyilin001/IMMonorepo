package com.xmtx.im.sharedsdk

import android.content.Context
import com.xmtx.im.swiftplatform.AndroidRuntimePlatform
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean

/** Account origin and realtime endpoint are part of the durable storage namespace. */
data class SharedEndpoint(val accountURL: String, val gatewayHost: String, val gatewayPort: Int = 7443) {
    init {
        val uri = URI(accountURL)
        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.query == null && uri.fragment == null && uri.path in listOf("", "/"))
        require(gatewayHost.isNotBlank() && gatewayHost.all { it.code in 33..126 } && gatewayPort in 1..65535)
    }
}
enum class SharedSessionState { SignedOut, SigningOut, Ready, Connecting, Connected, Offline, Closed }
enum class SharedError { InvalidConfiguration, InvalidInput, Busy, Closed, AuthenticationRequired, NetworkUnavailable, StorageUnavailable, OperationFailed, Cancelled }
class SharedSdkException(val reason: SharedError) : Exception(reason.name)
data class SharedConversation(
    val id: String, val title: String, val preview: String,
    val unread: Long = 0, val isGroup: Boolean = false, val updatedAt: Long? = null, val peerID: String? = null,
    val isPinned: Boolean = false, val isArchived: Boolean = false, val muteUntil: Long? = null
)
private fun JSONObject.optionalLong(key: String): Long? = if (isNull(key)) null else getLong(key)
private fun JSONObject.conversation() = SharedConversation(
    getString("id"), getString("title"), getString("preview"), optLong("unread"),
    optBoolean("isGroup"), optionalLong("updatedAt"), optString("peerID").takeIf(String::isNotEmpty),
    optBoolean("isPinned"), optBoolean("isArchived"), optionalLong("muteUntil")
)
data class SharedEntity(val kind: String, val offset: Int, val length: Int, val url: String?)
data class SharedMessage(val id: String, val senderID: String, val text: String, val sequence: Long, val withdrawn: Boolean, val hasMedia: Boolean, val attachments: PersistentList<SharedAttachment>, val revision: Long, val canMutate: Boolean, val readByPeer: Boolean, val replyToID: String?, val replyPreview: String?, val forwardedFromID: String?, val createdAt: Long? = null, val mentionSummary: String? = null, val entities: PersistentList<SharedEntity> = persistentListOf(), val roomSequence: Long = 0, val isPinned: Boolean = false)
enum class SharedSendStatus { Preparing, Pending, WaitingForNetwork, WaitingForAuthentication, AcceptedAwaitingProjection, ConfirmingOutcome, NeedsAttention, ExpiredUnsubmitted, Closed, Rejected }
data class SharedPendingMessage(val id: String, val text: String, val status: SharedSendStatus, val preparationStatus: String? = null, val createdAt: Long? = null,
                              val preparedAttachments: Long? = null, val totalAttachments: Long? = null)
data class SharedChat(val roomID: String, val messages: PersistentList<SharedMessage>, val pending: PersistentList<SharedPendingMessage>, val hasOlder: Boolean, val isLatest: Boolean, val hasMorePending: Boolean, val pendingPage: Int, val focusMessageID: String?)
data class SharedDeviceSession(val deviceID: String, val deviceName: String, val platform: String, val createdAt: Long, val lastActiveAt: Long, val isCurrentDevice: Boolean)
data class SharedDeviceSessions(val sessions: PersistentList<SharedDeviceSession>, val nextCursor: String?)
data class SharedFavoriteMessage(val id: String, val roomID: String, val roomTitle: String, val senderID: String, val text: String, val createdAt: Long?, val attachmentNames: List<String>)
data class SharedFavorites(val messages: List<SharedFavoriteMessage>, val hasMore: Boolean)
data class SharedPrivacy(val allowsStrangerMessages: Boolean?, val allowsUserAdd: Boolean?, val allowsDirectReadReceipts: Boolean?,
    val allowsGroupReadReceipts: Boolean?, val allowsOnlinePresence: Boolean?, val allowsTypingIndicators: Boolean?, val blockedUsers: List<String>)
data class SharedSnapshot(val state: SharedSessionState, val userID: String?, val allowsStrangerMessages: Boolean?, val appliedSequence: Long,
    val acknowledgedSequence: Long, val connections: Long, val conversations: PersistentList<SharedConversation>, val failure: SharedError?, val hasMoreConversations: Boolean, val isFirstConversationPage: Boolean, val chat: SharedChat?, val directory: SharedDirectory?, val resource: SharedResourceView?, val messaging: SharedMessagingView?, val windowID: String? = null, val deviceSessions: SharedDeviceSessions? = null, val privacy: SharedPrivacy? = null, val favorites: SharedFavorites? = null)

internal object NativeSharedSDK {
    init { System.loadLibrary("IMV2SharedSDK") }
    external fun create(configuration: ByteArray): Long
    external fun submit(client: Long, request: ByteArray): Long
    external fun poll(operation: Long): ByteArray?
    external fun cancel(operation: Long)
    external fun release(operation: Long): Int
    external fun releaseClient(client: Long): Int
    external fun active(): Int
    external fun clients(): Int
}

/** One closeable account owner. Tokens and registration proofs never cross the public Kotlin API.
 * close() cancels/drains in-flight Swift work, stops runtime and closes SQLite, retaining credentials.
 * The caller owns foregroundStates collection and must cancel it before releasing its UI lifecycle.
 */
class SharedClient private constructor(private val handle: Long) {
    private val mutation = Mutex()
    private val closeMutex = Mutex()
    private val monitor = Any()
    private val operations = mutableSetOf<Long>()
    private var closing = false
    private var closed = false
    private val foreground = AtomicBoolean(false)
    companion object {
        suspend fun open(context: Context, endpoint: SharedEndpoint): SharedClient {
            val created = java.util.concurrent.atomic.AtomicReference<SharedClient?>()
            try { return withContext(Dispatchers.IO) {
            NativeSharedSDK.active()
            AndroidRuntimePlatform.install(context.applicationContext)
            val root = File(context.applicationContext.noBackupFilesDir, "shared-sdk").apply { check(isDirectory || mkdirs()) }
            val configuration = JSONObject().put("accountURL", endpoint.accountURL.trimEnd('/'))
                .put("gatewayHost", endpoint.gatewayHost).put("gatewayPort", endpoint.gatewayPort).put("storageDirectory", root.path)
            val handle = NativeSharedSDK.create(configuration.toString().toByteArray())
            if (handle == 0L) throw SharedSdkException(SharedError.InvalidConfiguration)
            SharedClient(handle).also { created.set(it) }
            } } catch (error: Exception) {
                withContext(NonCancellable) { created.get()?.close() }
                throw error
            }
        }
        /** Non-sensitive process diagnostics for leak verification and integration monitoring. */
        fun activeOperationCount(): Int = NativeSharedSDK.active()
        fun activeClientCount(): Int = NativeSharedSDK.clients()
    }
    /** Independent query ownership for separate panes/windows; opening one never selects a chat. */
    suspend fun openConversationList(isArchived: Boolean = false, pageSize: Int = 50): SharedConversationWindow =
        openWindow(JSONObject().put("operation", "openListWindow").put("archived", isArchived).put("limit", pageSize))
    suspend fun openMessageTimeline(roomID: String, pageSize: Int = 50): SharedConversationWindow =
        openWindow(JSONObject().put("operation", "openTimelineWindow").put("roomID", roomID).put("limit", pageSize))

    /** Null keeps the current field; muteUntil uses epoch milliseconds and 0 clears the mute. */
    suspend fun setConversationState(roomID: String, isPinned: Boolean? = null, isArchived: Boolean? = null,
                                     muteUntil: Long? = null): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "conversationState").put("roomID", roomID).apply {
            if (isPinned != null) put("isPinned", isPinned)
            if (isArchived != null) put("archived", isArchived)
            if (muteUntil != null) put("muteUntil", muteUntil)
        })
    }

    private suspend fun openWindow(request: JSONObject): SharedConversationWindow {
        var completedID: String? = null
        try {
            val initial = execute(request, completedWindow = { completedID = it })
            currentCoroutineContext().ensureActive()
            return SharedConversationWindow(this, requireNotNull(initial.windowID))
        } catch (error: Throwable) {
            // Also adopts a successful native result discarded by prompt dispatcher cancellation.
            withContext(NonCancellable) {
                completedID?.let { id ->
                    try { SharedConversationWindow(this@SharedClient, id).close() }
                    catch (cleanup: Throwable) { error.addSuppressed(cleanup) }
                }
            }
            throw error
        }
    }
    // A long-running observation must not hold the account mutation mutex.
    internal suspend fun windowCall(operation: String, windowID: String): SharedSnapshot =
        execute(JSONObject().put("operation", operation).put("windowID", windowID))

    suspend fun restore(): SharedSnapshot = mutate("restore")
    suspend fun login(account: String, password: String): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "login").put("account", account).put("password", password))
    }
    suspend fun deviceSessions(cursor: String? = null): SharedSnapshot = execute(JSONObject().put("operation", "deviceSessions").apply {
        if (cursor != null) put("intentID", cursor)
    })
    suspend fun favorites(next: Boolean = false): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "favorites").put("action", if (next) "next" else "first"))
    }
    suspend fun pinMessage(roomID: String, messageID: String, roomSequence: Long, isPinned: Boolean): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "pinMessage").put("roomID", roomID).put("messageID", messageID)
            .put("offset", roomSequence).put("flag1", isPinned))
    }
    suspend fun setFavorite(roomID: String, messageID: String, favorited: Boolean): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "setFavorite").put("roomID", roomID).put("messageID", messageID).put("flag1", favorited))
    }
    suspend fun privacy(): SharedSnapshot = mutation.withLock { execute(JSONObject().put("operation", "privacy")) }
    suspend fun setPrivacy(kind: String, flag1: Boolean?, flag2: Boolean?): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "setPrivacy").put("action", kind).apply {
            if (flag1 != null) put("flag1", flag1)
            if (flag2 != null) put("flag2", flag2)
        })
    }
    suspend fun revokeDevice(deviceID: String?, all: Boolean): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "revokeDevice").put("action", if (all) "all" else "device").apply {
            if (deviceID != null) put("targetUserID", deviceID)
        })
    }
    suspend fun passwordLifecycle(account: String, action: String, currentPassword: String?, newPassword: String?, recoveryCode: String?): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "passwordLifecycle").put("account", account).put("action", action).apply {
            if (currentPassword != null) put("password", currentPassword)
            if (newPassword != null) put("newPassword", newPassword)
            if (recoveryCode != null) put("recoveryCode", recoveryCode)
        })
    }
    suspend fun register(account: String, password: String, publicHandle: String, displayName: String): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "register").put("account", account).put("password", password)
            .put("publicHandle", publicHandle).put("displayName", displayName))
    }
    suspend fun connect(): SharedSnapshot = mutate("connect")
    suspend fun disconnect(): SharedSnapshot = mutate("disconnect")
    suspend fun synchronize(): SharedSnapshot = mutate("synchronize")
    suspend fun snapshot(): SharedSnapshot = mutate("snapshot")
    /** Persistent local exit + revocation handoff; cancel the foreground collector before calling. */
    suspend fun signOut(): SharedSnapshot = withContext(NonCancellable) { mutate("signOut") }
    suspend fun openConversation(roomID: String, messageID: String? = null): SharedSnapshot = directoryCall("openConversation", "roomID" to roomID, "messageID" to messageID)
    suspend fun locateMessage(roomID: String, messageID: String): SharedSnapshot = directoryCall("locateMessage", "roomID" to roomID, "messageID" to messageID)
    suspend fun searchMessages(query: String, roomID: String? = null): SharedSnapshot = directoryCall("searchMessages", "text" to query, "roomID" to roomID)
    suspend fun nextSearch(): SharedSnapshot = directoryCall("searchMessages", "action" to "next")
    suspend fun clearMessaging(): SharedSnapshot = mutate("clearMessaging")
    suspend fun editMessage(roomID: String, messageID: String, revision: Long, text: String): SharedSnapshot = directoryCall("messageAction", "roomID" to roomID, "messageID" to messageID, "revision" to revision, "action" to "edit", "text" to text)
    suspend fun withdrawMessage(roomID: String, messageID: String, revision: Long): SharedSnapshot = directoryCall("messageAction", "roomID" to roomID, "messageID" to messageID, "revision" to revision, "action" to "withdraw")
    suspend fun retryMessageAction(roomID: String, id: String): SharedSnapshot = directoryCall("messageAction", "roomID" to roomID, "intentID" to id, "action" to "retry")
    suspend fun retryReadReceipt(roomID: String): SharedSnapshot = directoryCall("messageAction", "roomID" to roomID, "action" to "readRetry")
    suspend fun markVisibleMessages(roomID: String, ids: List<String>): SharedSnapshot = directoryCall("markVisibleMessages", "roomID" to roomID, "messageIDs" to org.json.JSONArray(ids))
    suspend fun messageReaders(roomID: String, messageID: String, next: Boolean = false): SharedSnapshot = directoryCall("messageReaders", "roomID" to roomID, "messageID" to messageID, "action" to if (next) "next" else "first")
    suspend fun forwardMessage(roomID: String, messageID: String, revision: Long, targetRoomID: String): SharedSnapshot = directoryCall("forwardMessage", "roomID" to roomID, "messageID" to messageID, "revision" to revision, "targetRoomID" to targetRoomID)
    suspend fun forwardMessage(roomID: String, messageID: String, revision: Long, targetRoomIDs: List<String>): SharedSnapshot =
        directoryCall("forwardMessage", "roomID" to roomID, "messageID" to messageID, "revision" to revision, "targetRoomIDs" to org.json.JSONArray(targetRoomIDs))
    suspend fun retryForward(roomID: String, id: String): SharedSnapshot = directoryCall("interactionAction", "roomID" to roomID, "intentID" to id, "action" to "retryForward")
    suspend fun cancelForward(roomID: String, id: String): SharedSnapshot = directoryCall("interactionAction", "roomID" to roomID, "intentID" to id, "action" to "cancelForward")
    suspend fun nextConversations(): SharedSnapshot = mutate("conversationsNext")
    suspend fun firstConversations(): SharedSnapshot = mutate("conversationsFirst")
    suspend fun olderMessages(): SharedSnapshot = mutate("messagesOlder")
    suspend fun latestMessages(): SharedSnapshot = mutate("messagesLatest")
    suspend fun nextPending(): SharedSnapshot = mutate("pendingNext")
    suspend fun firstPending(): SharedSnapshot = mutate("pendingFirst")
    suspend fun sendText(roomID: String, text: String, replyToMessageID: String? = null, mentions: List<String>? = null): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "sendText").put("roomID", roomID).put("text", text).apply {
            if (replyToMessageID != null) put("replyToMessageID", replyToMessageID)
            if (!mentions.isNullOrEmpty()) put("mentions", org.json.JSONArray(mentions))
        })
    }
    suspend fun resendUnsent(intentID: String): SharedSnapshot = directoryCall("resendUnsent", "intentID" to intentID)
    suspend fun retrySend(intentID: String): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", "retrySend").put("intentID", intentID))
    }
    suspend fun contacts(scope: SharedContactScope): SharedSnapshot = directoryCall("contacts", "scope" to scope.wire)
    suspend fun nextContacts(): SharedSnapshot = mutate("contactsNext")
    suspend fun firstGroups(): SharedSnapshot = mutate("groupsFirst")
    suspend fun nextGroups(): SharedSnapshot = mutate("groupsNext")
    suspend fun lookupIdentity(handle: String): SharedSnapshot = directoryCall("lookupIdentity", "text" to handle)
    suspend fun clearDiscovery(): SharedSnapshot = mutate("clearDiscovery")
    suspend fun socialAction(targetUserID: String, action: SharedSocialAction): SharedSnapshot = directoryCall("socialAction", "targetUserID" to targetUserID, "action" to action.wire)
    suspend fun openDirect(targetUserID: String): SharedSnapshot = directoryCall("openDirect", "targetUserID" to targetUserID)
    suspend fun createGroup(title: String, members: List<String>): SharedSnapshot = directoryCall("createGroup", "text" to title, "members" to org.json.JSONArray(members))
    suspend fun openGroup(roomID: String): SharedSnapshot = directoryCall("openGroup", "roomID" to roomID)
    suspend fun nextGroupMembers(roomID: String): SharedSnapshot = directoryCall("groupMembersNext", "roomID" to roomID)
    /** The revision is the one displayed at confirmation, never implicitly refreshed on retry. */
    suspend fun groupAction(roomID: String, action: SharedGroupAction, revision: Long, targetUserID: String? = null,
        text: String? = null, role: SharedRole? = null, permissions: List<SharedPermission>? = null): SharedSnapshot =
        directoryCall("groupAction", "roomID" to roomID, "action" to action.wire, "revision" to revision, "targetUserID" to targetUserID,
            "text" to text, "role" to role?.wire, "permissions" to permissions?.let { org.json.JSONArray(it.map(SharedPermission::wire)) })
    suspend fun profiles(page: String, context: String, roomID: String?, userIDs: List<String>): SharedSnapshot =
        directoryCall("profiles", "page" to page, "scope" to context, "roomID" to roomID, "members" to org.json.JSONArray(userIDs))
    suspend fun clearProfiles(page: String): SharedSnapshot = directoryCall("clearProfiles", "page" to page)
    /** Display-only read; intentionally bypasses the account mutation mutex. */
    suspend fun avatar(userID: String, context: String, roomID: String? = null): SharedSnapshot =
        execute(JSONObject().put("operation", "avatar").put("page", "avatar").put("scope", context)
            .put("targetUserID", userID).apply { if (roomID != null) put("roomID", roomID) })
    suspend fun groupNickname(roomID: String): SharedSnapshot = directoryCall("groupNickname", "roomID" to roomID)
    suspend fun saveGroupNickname(roomID: String, name: String?, revision: Long?): SharedSnapshot =
        directoryCall("saveGroupNickname", "roomID" to roomID, "text" to (name ?: ""), "revision" to revision)
    suspend fun openProfile(userID: String, context: String = "relationship", roomID: String? = null): SharedSnapshot =
        directoryCall("openProfile", "targetUserID" to userID, "scope" to context, "roomID" to roomID)
    suspend fun saveAlias(userID: String, name: String?, revision: Long?): SharedSnapshot = directoryCall("saveAlias", "targetUserID" to userID, "text" to (name ?: ""), "revision" to revision)
    suspend fun invitations(roomID: String): SharedSnapshot = directoryCall("invitations", "roomID" to roomID)
    suspend fun nextInvitations(roomID: String): SharedSnapshot = directoryCall("invitationsNext", "roomID" to roomID)
    suspend fun refreshInvite(): SharedSnapshot = mutate("refreshInvite")
    suspend fun previewInvite(input: String): SharedSnapshot = directoryCall("previewInvite", "text" to input)
    suspend fun inviteAction(roomID: String, action: SharedInviteAction, revision: Long? = null, id: String? = null, note: String? = null): SharedSnapshot =
        directoryCall("inviteAction", "roomID" to roomID, "action" to action.wire, "revision" to revision, "intentID" to id, "text" to note)
    suspend fun muteMember(roomID: String, userID: String, revision: Long): SharedSnapshot = directoryCall("muteMember", "roomID" to roomID, "targetUserID" to userID, "revision" to revision)
    suspend fun moderateMemberRemoval(roomID: String, userID: String, revision: Long): SharedSnapshot =
        directoryCall("moderateMemberRemoval", "roomID" to roomID, "targetUserID" to userID, "revision" to revision)
    suspend fun discardDirectoryDraft(id: String): SharedSnapshot = directoryCall("discardDirectoryDraft", "intentID" to id)
    suspend fun retryDirectoryWork(id: String): SharedSnapshot = directoryCall("retryDirectoryWork", "intentID" to id)
    suspend fun openAvatarEditor(roomID: String? = null): SharedSnapshot = directoryCall("openAvatarEditor", "roomID" to roomID)
    suspend fun changeAvatar(roomID: String?, revision: Long, jpeg: String? = null, width: Int? = null, height: Int? = null,
                             text: String? = null, action: String? = null): SharedSnapshot = directoryCall("changeAvatar", "roomID" to roomID,
        "revision" to revision, "image" to jpeg, "width" to width, "height" to height, "text" to text, "action" to action)
    suspend fun avatarAction(roomID: String?, id: String, action: SharedAvatarAction): SharedSnapshot = directoryCall("avatarAction", "roomID" to roomID, "intentID" to id, "action" to action.wire)
    /** Stream device bytes in bounded chunks; Swift owns staging, validation and atomic handoff. */
    suspend fun importAttachment(roomID: String, name: String, contentType: String, input: java.io.InputStream, width: Int? = null, height: Int? = null): SharedSnapshot = mutation.withLock {
        withContext(Dispatchers.IO) {
            var finished = false
            try {
                val begin = execute(JSONObject().put("operation", "beginAttachment").put("roomID", roomID).put("displayName", name).put("contentType", contentType).apply { if (width != null) put("width", width); if (height != null) put("height", height) })
                val id = checkNotNull(begin.resource?.importID); var offset = 0L; val buffer = ByteArray(65_536)
                while (true) {
                    ensureActive(); val count = runInterruptible { input.read(buffer) }; if (count < 0) break; if (count == 0) continue
                    execute(JSONObject().put("operation", "appendAttachment").put("intentID", id).put("offset", offset).put("data", android.util.Base64.encodeToString(buffer, 0, count, android.util.Base64.NO_WRAP)))
                    offset += count
                }
                execute(JSONObject().put("operation", "finishAttachment").put("intentID", id).put("offset", offset)).also { finished = true }
            } finally { if (!finished) withContext(NonCancellable) { runCatching { execute(JSONObject().put("operation", "clearResources")) } } }
        }
    }
    suspend fun sendAttachment(roomID: String, assetID: String, text: String = ""): SharedSnapshot = directoryCall("sendAttachment", "roomID" to roomID, "intentID" to assetID, "text" to text)
    suspend fun clearResources(): SharedSnapshot = mutate("clearResources")
    suspend fun openResource(roomID: String, messageID: String, mediaID: String): SharedSnapshot = directoryCall("openResource", "roomID" to roomID, "messageID" to messageID, "mediaID" to mediaID)
    suspend fun downloadResource(): SharedSnapshot = mutate("downloadResource")
    suspend fun previewResource(): SharedSnapshot = mutate("previewResource")
    suspend fun transferAction(id: String, action: SharedTransferAction): SharedSnapshot = directoryCall("transferAction", "intentID" to id, "action" to action.wire)
    suspend fun cancelAttachmentSend(id: String): SharedSnapshot = directoryCall("cancelAttachmentSend", "intentID" to id)
    /** No cache path escapes Swift. Each chunk borrows the same authorized resource again. */
    suspend fun exportResource(output: java.io.OutputStream): SharedSnapshot = mutation.withLock {
        withContext(Dispatchers.IO) {
            try {
                val begin = execute(JSONObject().put("operation", "beginResourceRead")); val id = checkNotNull(begin.resource?.readID)
                var offset = 0L
                while (true) {
                    ensureActive()
                    val value = execute(JSONObject().put("operation", "readResource").put("intentID", id).put("offset", offset))
                    val bytes = android.util.Base64.decode(checkNotNull(value.resource?.chunk), android.util.Base64.NO_WRAP)
                    if (bytes.isEmpty()) break
                    runInterruptible { output.write(bytes) }; offset += bytes.size
                }
                output.flush(); execute(JSONObject().put("operation", "endResourceRead"))
            } finally { withContext(NonCancellable) { runCatching { execute(JSONObject().put("operation", "endResourceRead")) } } }
        }
    }
    private suspend fun directoryCall(operation: String, vararg fields: Pair<String, Any?>): SharedSnapshot = mutation.withLock {
        execute(JSONObject().put("operation", operation).apply { fields.forEach { (key, value) -> if (value != null) put(key, value) } })
    }
    private suspend fun mutate(operation: String) = mutation.withLock { execute(JSONObject().put("operation", operation)) }

    /** Foreground-only reconnect policy; cancellation drains the old runtime before returning.
     * Authorization failures stop retries. Temporary transport failures back off to at most 30s.
     */
    fun foregroundStates(): Flow<SharedSnapshot> = flow {
        check(foreground.compareAndSet(false, true)) { "Only one foreground owner is allowed" }
        var backoff = 1000L
        try {
            while (currentCoroutineContext().isActive) {
                try {
                    disconnect()
                    emit(connect())
                    while (currentCoroutineContext().isActive) {
                        val value = snapshot(); emit(value)
                        if (value.state != SharedSessionState.Connected) break
                        backoff = 1000
                        delay(500)
                    }
                } catch (error: SharedSdkException) {
                    if (error.reason !in setOf(SharedError.NetworkUnavailable, SharedError.OperationFailed)) throw error
                    emit(snapshot())
                }
                delay(backoff); backoff = (backoff * 2).coerceAtMost(30_000)
            }
        } finally {
            try {
                withContext(NonCancellable) {
                    if (!synchronized(monitor) { closing }) try { disconnect() } catch (error: SharedSdkException) {
                        if (error.reason != SharedError.Closed) throw error
                    }
                }
            } finally { foreground.set(false) }
        }
    }

    suspend fun close() = withContext(NonCancellable + Dispatchers.IO) {
        closeMutex.withLock {
            val pending = synchronized(monitor) {
                if (closed) return@withLock
                closing = true; operations.toList()
            }
            try {
                pending.forEach(NativeSharedSDK::cancel)
                while (synchronized(monitor) { operations.isNotEmpty() }) delay(10)
                mutation.withLock {
                    execute(JSONObject().put("operation", "close"), allowClosing = true)
                    check(NativeSharedSDK.releaseClient(handle) == 1) { "Client not physically drained" }
                    synchronized(monitor) { closed = true }
                }
            } finally { synchronized(monitor) { if (!closed) closing = false } }
        }
    }

    private suspend fun execute(request: JSONObject, allowClosing: Boolean = false, completedWindow: ((String) -> Unit)? = null): SharedSnapshot = withContext(Dispatchers.IO) {
        val startedAt = android.os.SystemClock.elapsedRealtime()
        val operation = synchronized(monitor) {
            if (closed || (closing && !allowClosing)) throw SharedSdkException(SharedError.Closed)
            val id = NativeSharedSDK.submit(handle, request.toString().toByteArray())
            if (id == 0L) throw SharedSdkException(SharedError.Busy)
            operations.add(id); id
        }
        try {
            val result = awaitResult(operation)
            if (result.has("error")) throw SharedSdkException(error(result.getString("error")))
            decode(result.getJSONObject("snapshot"), startedAt)
        } finally {
            withContext(NonCancellable) {
                NativeSharedSDK.cancel(operation)
                // No early timeout/release: Swift publishes a result only after physical cleanup.
                val finalResult = awaitResult(operation)
                check(NativeSharedSDK.release(operation) == 1)
                synchronized(monitor) { operations.remove(operation) }
                finalResult.optJSONObject("snapshot")?.optString("windowID")?.takeIf { it.isNotEmpty() }?.let { completedWindow?.invoke(it) }
            }
        }
    }
    private suspend fun awaitResult(operation: Long): JSONObject {
        while (true) { NativeSharedSDK.poll(operation)?.let { return JSONObject(it.toString(Charsets.UTF_8)) }; delay(10) }
    }
    private fun error(value: String): SharedError = SharedError.entries.firstOrNull { it.name.equals(value, true) } ?: SharedError.OperationFailed
    private fun decode(value: JSONObject, startedAt: Long): SharedSnapshot {
        val rows = value.getJSONArray("conversations")
        return SharedSnapshot(SharedSessionState.entries.first { it.name.equals(value.getString("state"), true) },
            value.optString("userID").takeIf { it.isNotEmpty() }, if (value.has("allowsStrangerMessages")) value.getBoolean("allowsStrangerMessages") else null, value.getLong("appliedSequence"), value.getLong("acknowledgedSequence"),
            value.getLong("connections"), (0 until rows.length()).map { index -> rows.getJSONObject(index).conversation() }.toPersistentList(),
            value.optString("failure").takeIf { it.isNotEmpty() }?.let(::error), value.getBoolean("hasMoreConversations"), value.getBoolean("isFirstConversationPage"),
            value.optJSONObject("chat")?.let { chat ->
                val messages = chat.getJSONArray("messages"); val pending = chat.getJSONArray("pending")
                SharedChat(chat.getString("roomID"), (0 until messages.length()).map { index -> messages.getJSONObject(index).let {
                    SharedMessage(it.getString("id"), it.getString("senderID"), it.getString("text"), it.getLong("sequence"), it.getBoolean("withdrawn"), it.getBoolean("hasMedia"), it.getJSONArray("attachments").let { rows -> (0 until rows.length()).map { index -> decodeAttachment(rows.getJSONObject(index)) }.toPersistentList() }, it.getLong("revision"), it.getBoolean("canMutate"), it.getBoolean("readByPeer"), it.optString("replyToID").takeIf(String::isNotEmpty), it.optString("replyPreview").takeIf(String::isNotEmpty), it.optString("forwardedFromID").takeIf(String::isNotEmpty), it.optionalLong("createdAt"), it.optString("mentionSummary").takeIf(String::isNotEmpty),
                        (0 until it.optJSONArray("entities").let { rows -> rows?.length() ?: 0 }).map { index ->
                            val entity = it.getJSONArray("entities").getJSONObject(index)
                            SharedEntity(entity.getString("kind"), entity.getInt("offset"), entity.getInt("length"),
                                entity.optString("url").takeIf(String::isNotEmpty))
                        }.toPersistentList(), it.getLong("roomSequence"), it.getBoolean("isPinned"))
                } }.toPersistentList(), (0 until pending.length()).map { index -> pending.getJSONObject(index).let {
                    SharedPendingMessage(it.getString("id"), it.getString("text"), SharedSendStatus.entries.first { status -> status.name.equals(it.getString("status"), true) },
                        it.optString("preparationStatus").takeIf(String::isNotEmpty), it.optionalLong("createdAt"),
                        it.optionalLong("preparedAttachments"), it.optionalLong("totalAttachments"))
                } }.toPersistentList(), chat.getBoolean("hasOlder"), chat.getBoolean("isLatest"), chat.getBoolean("hasMorePending"), chat.getInt("pendingPage"), chat.optString("focusMessageID").takeIf { it.isNotEmpty() })
            }, value.optJSONObject("directory")?.let { decodeDirectory(it, startedAt) }, value.optJSONObject("resource")?.let { decodeResources(it, startedAt) }, value.optJSONObject("messaging")?.let { decodeMessaging(it, startedAt) }, windowID = value.optString("windowID").takeIf { it.isNotEmpty() },
            privacy = value.optJSONObject("privacy")?.let { privacy ->
                val blocked = privacy.getJSONArray("blockedUsers")
                SharedPrivacy(
                    if (privacy.has("allowsStrangerMessages")) privacy.getBoolean("allowsStrangerMessages") else null,
                    if (privacy.has("allowsUserAdd")) privacy.getBoolean("allowsUserAdd") else null,
                    if (privacy.has("allowsDirectReadReceipts")) privacy.getBoolean("allowsDirectReadReceipts") else null,
                    if (privacy.has("allowsGroupReadReceipts")) privacy.getBoolean("allowsGroupReadReceipts") else null,
                    if (privacy.has("allowsOnlinePresence")) privacy.getBoolean("allowsOnlinePresence") else null,
                    if (privacy.has("allowsTypingIndicators")) privacy.getBoolean("allowsTypingIndicators") else null,
                    (0 until blocked.length()).map { blocked.getString(it) })
            }, favorites = value.optJSONObject("favorites")?.let { favorites ->
                val rows = favorites.getJSONArray("messages")
                SharedFavorites((0 until rows.length()).map { index -> rows.getJSONObject(index).let {
                    val names = it.getJSONArray("attachmentNames")
                    SharedFavoriteMessage(it.getString("id"), it.getString("roomID"), it.getString("roomTitle"),
                        it.getString("senderID"), it.getString("text"), it.optionalLong("createdAt"),
                        (0 until names.length()).map { i -> names.getString(i) })
                } }, favorites.getBoolean("hasMore"))
            }, deviceSessions = value.optJSONObject("deviceSessions")?.let { sessions ->
                val rows = sessions.getJSONArray("sessions")
                SharedDeviceSessions((0 until rows.length()).map { index -> rows.getJSONObject(index).let {
                    SharedDeviceSession(it.getString("deviceID"), it.getString("deviceName"), it.getString("platform"),
                        it.getLong("createdAt"), it.getLong("lastActiveAt"), it.getBoolean("isCurrentDevice"))
                } }.toPersistentList(), sessions.optString("nextCursor").takeIf(String::isNotEmpty))
            })
    }
}
