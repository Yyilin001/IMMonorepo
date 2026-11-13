package com.xmtx.im

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import com.xmtx.im.sharedsdk.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal object SharedAppSettings {
    fun load(context: Context): SharedEndpoint? {
        val preferences = context.getSharedPreferences("shared-endpoint", Context.MODE_PRIVATE)
        val url = preferences.getString("account", null) ?: return null
        return runCatching { SharedEndpoint(url, preferences.getString("host", "")!!, preferences.getInt("port", 7443)) }.getOrNull()
    }
    fun save(context: Context, endpoint: SharedEndpoint) {
        check(context.getSharedPreferences("shared-endpoint", Context.MODE_PRIVATE).edit()
            .putString("account", endpoint.accountURL).putString("host", endpoint.gatewayHost).putInt("port", endpoint.gatewayPort).commit())
    }
}
internal data class SharedAppState(val snapshot: SharedSnapshot? = null, val busy: Boolean = false,
    val reportingVisible: Boolean = false, val error: String? = null, val endpoint: SharedEndpoint? = null, val generation: Long = 0, val exitPending: Boolean = false)

/** UI owns a session, not protocol or database implementations. The owner scope remains alive
 * through onCleared only to drain Swift, then cancels itself; Activity stop drains foreground I/O. */
internal class SharedAppViewModel(application: Application) : AndroidViewModel(application) {
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val lifecycleGate = Mutex()
    private val mutable = MutableStateFlow(SharedAppState(endpoint = SharedAppSettings.load(application)))
    val state = mutable.asStateFlow()
    private var client: SharedClient? = null
    private var foregroundJob: Job? = null
    private var operation: Job? = null
    private var readReportJob: Job? = null
    private var active = false
    init {
        mutable.value.endpoint?.let { endpoint ->
            operation = owner.launch {
                lifecycleGate.withLock {
                    mutable.value = mutable.value.copy(busy = true)
                    try {
                        val opened = SharedClient.open(application, endpoint); client = opened
                        mutable.value = mutable.value.copy(snapshot = opened.restore(), error = null)
                        startForeground()
                    } catch (error: Exception) { handle(error) }
                    finally { mutable.value = mutable.value.copy(busy = false) }
                }
            }
        }
    }
    fun foreground(value: Boolean) {
        active = value
        if (value) {
            startForeground()
            if (client != null && mutable.value.snapshot?.userID == null && operation?.isActive != true) {
                operation = owner.launch {
                    lifecycleGate.withLock {
                        try { mutable.value = mutable.value.copy(snapshot = client?.restore()); startForeground() }
                        catch (error: Exception) { handle(error) }
                    }
                }
            }
        } else {
            foregroundJob?.cancel(); operation?.cancel(); readReportJob?.cancel()
            mutable.value.snapshot?.let { snapshot ->
                mutable.value = mutable.value.copy(snapshot = snapshot.copy(messaging = null, resource = null, directory = snapshot.directory?.copy(identity = null, profiles = kotlinx.collections.immutable.persistentListOf(), community = null, avatarEditor = null)))
                if (snapshot.userID != null) clearDiscovery()
            }
        }
    }
    private fun startForeground() {
        val current = client ?: return
        if (!active || mutable.value.snapshot?.userID == null || foregroundJob?.isActive == true) return
        val generation = mutable.value.generation
        val previous = foregroundJob
        foregroundJob = owner.launch {
            previous?.cancelAndJoin()
            try { current.foregroundStates().collect { if (mutable.value.generation == generation) mutable.value = mutable.value.copy(snapshot = it) } }
            catch (error: Exception) { handle(error) }
        }
    }
    fun login(account: String, password: String, url: String, port: Int) {
        if (mutable.value.busy || mutable.value.exitPending) return
        operation = owner.launch {
            lifecycleGate.withLock {
                mutable.value = mutable.value.copy(busy = true, error = null)
                try {
                    val endpoint = SharedEndpoint(url, java.net.URI(url).host ?: "", port)
                    if (mutable.value.endpoint != endpoint) { foregroundJob?.cancelAndJoin(); client?.close(); client = null }
                    val current = client ?: SharedClient.open(getApplication(), endpoint).also { client = it }
                    withContext(Dispatchers.IO) { SharedAppSettings.save(getApplication(), endpoint) }
                    mutable.value = mutable.value.copy(endpoint = endpoint, snapshot = current.login(account, password))
                    startForeground()
                } catch (error: Exception) { handle(error) }
                finally { mutable.value = mutable.value.copy(busy = false) }
            }
        }
    }
    private fun command(action: suspend (SharedClient) -> SharedSnapshot) {
        if (mutable.value.busy || mutable.value.exitPending) return
        mutable.value = mutable.value.copy(busy = true, error = null)
        operation = owner.launch {
            lifecycleGate.withLock {
                try { client?.let { mutable.value = mutable.value.copy(snapshot = action(it)) } }
                catch (error: Exception) { handle(error) }
                finally { mutable.value = mutable.value.copy(busy = false) }
            }
        }
    }
    fun openConversation(roomID: String, messageID: String? = null) = command { it.openConversation(roomID, messageID) }
    fun searchMessages(query: String, roomID: String?) = command { it.searchMessages(query, roomID) }
    fun nextSearch() = command { it.nextSearch() }
    fun clearMessaging() {
        val generation = mutable.value.generation
        owner.launch { lifecycleGate.withLock {
            if (mutable.value.generation == generation) try { client?.let { mutable.value = mutable.value.copy(snapshot = it.clearMessaging()) } } catch (error: Exception) { handle(error) }
        } }
    }
    fun editMessage(room: String, message: SharedMessage, text: String, saved: () -> Unit) = command { it.editMessage(room, message.id, message.revision, text).also { saved() } }
    fun withdrawMessage(room: String, message: SharedMessage, saved: () -> Unit) = command { it.withdrawMessage(room, message.id, message.revision).also { saved() } }
    fun retryMessageAction(room: String, id: String) = command { it.retryMessageAction(room, id) }
    fun retryReadReceipt(room: String) = command { it.retryReadReceipt(room) }
    fun messageReaders(room: String, message: String, next: Boolean = false) = command { it.messageReaders(room, message, next) }
    fun markVisibleMessages(room: String, ids: List<String>): Boolean {
        if (!active || ids.isEmpty() || mutable.value.busy || mutable.value.reportingVisible || mutable.value.exitPending) return false
        val generation = mutable.value.generation
        mutable.value = mutable.value.copy(reportingVisible = true)
        readReportJob = owner.launch {
            try {
                lifecycleGate.withLock {
                    if (active && mutable.value.generation == generation && mutable.value.snapshot?.chat?.roomID == room) {
                        client?.let { current ->
                            val result = current.markVisibleMessages(room, ids)
                            if (active && mutable.value.generation == generation) mutable.value = mutable.value.copy(snapshot = result)
                        }
                    }
                }
            } catch (error: Exception) { if (active && mutable.value.generation == generation) handle(error) }
            finally { mutable.value = mutable.value.copy(reportingVisible = false) }
        }
        return true
    }
    fun reply(room: String, message: String, text: String, saved: () -> Unit) = command { current ->
        withContext(NonCancellable) { current.sendText(room, text, message) }.also { saved() }
    }
    fun react(room: String, message: String, reaction: String, present: Boolean) = command { it.reactMessage(room, message, reaction, present) }
    fun forward(room: String, message: String, revision: Long, target: String, saved: () -> Unit) = command { it.forwardMessage(room, message, revision, target).also { saved() } }
    fun retryReaction(room: String, id: String) = command { it.retryReaction(room, id) }
    fun retryForward(room: String, id: String) = command { it.retryForward(room, id) }
    fun cancelForward(room: String, id: String) = command { it.cancelForward(room, id) }
    fun nextConversations() = command { it.nextConversations() }
    fun firstConversations() = command { it.firstConversations() }
    fun olderMessages() = command { it.olderMessages() }
    fun latestMessages() = command { it.latestMessages() }
    fun nextPending() = command { it.nextPending() }
    fun firstPending() = command { it.firstPending() }
    fun retrySend(id: String) = command { it.retrySend(id) }
    fun send(roomID: String, text: String) = command { current ->
        // This is only local durable enqueue, never a network wait. Stop/recreation drains it.
        withContext(NonCancellable) { current.sendText(roomID, text) }
    }
    fun contacts(scope: SharedContactScope) = command { it.contacts(scope) }
    fun nextContacts() = command { it.nextContacts() }
    fun firstGroups() = command { it.firstGroups() }
    fun nextGroups() = command { it.nextGroups() }
    fun lookupIdentity(handle: String) = command { it.lookupIdentity(handle) }
    fun clearDiscovery() { owner.launch { lifecycleGate.withLock {
        try { client?.let { mutable.value = mutable.value.copy(snapshot = it.clearDiscovery()) } }
        catch (error: Exception) { if (error is CancellationException) throw error }
    } } }
    fun socialAction(target: String, action: SharedSocialAction) = command { it.socialAction(target, action) }
    fun openDirect(target: String) = command { it.openDirect(target) }
    fun createGroup(title: String, members: List<String>) = command { it.createGroup(title, members) }
    fun openGroup(room: String) = command { it.openGroup(room) }
    fun nextGroupMembers(room: String) = command { it.nextGroupMembers(room) }
    fun groupAction(room: String, action: SharedGroupAction, revision: Long, target: String? = null, text: String? = null,
        role: SharedRole? = null, permissions: List<SharedPermission>? = null) = command { it.groupAction(room, action, revision, target, text, role, permissions) }
    fun openProfile(id: String) = command { it.openProfile(id) }
    fun saveAlias(id: String, name: String?, revision: Long?) = command { it.saveAlias(id, name, revision) }
    fun invitations(room: String) = command { it.invitations(room) }
    fun nextInvitations(room: String) = command { it.nextInvitations(room) }
    fun refreshInvite() = command { it.refreshInvite() }
    fun previewInvite(input: String) = command { it.previewInvite(input) }
    fun inviteAction(room: String, action: SharedInviteAction, revision: Long? = null, id: String? = null, note: String? = null) = command { it.inviteAction(room, action, revision, id, note) }
    fun importAttachment(room: String, uri: android.net.Uri, image: Boolean) = command { SharedDocumentIO.import(getApplication(), it, room, uri, image) }
    fun sendAttachment(room: String, id: String, text: String, sent: () -> Unit = {}) = command { it.sendAttachment(room, id, text).also { sent() } }
    fun clearResources() = command { it.clearResources() }
    fun openResource(room: String, message: String, media: String) = command { it.openResource(room, message, media) }
    fun downloadResource() = command { it.downloadResource() }
    fun previewResource() = command { it.previewResource() }
    fun transferAction(id: String, action: SharedTransferAction) = command { it.transferAction(id, action) }
    fun cancelAttachmentSend(id: String) = command { it.cancelAttachmentSend(id) }
    fun exportResource(room: String, message: String, media: String, uri: android.net.Uri, success: () -> Unit) = command {
        SharedDocumentIO.export(getApplication(), it, room, message, media, uri).also { success() }
    }
    fun openAvatarEditor(room: String?) = command { it.openAvatarEditor(room) }
    fun changeAvatar(room: String?, revision: Long, jpeg: String?) = command { it.changeAvatar(room, revision, jpeg, if (jpeg != null) 512 else null, if (jpeg != null) 512 else null) }
    fun avatarAction(room: String?, id: String, action: SharedAvatarAction) = command { it.avatarAction(room, id, action) }
    fun muteMember(room: String, user: String, revision: Long) = command { it.muteMember(room, user, revision) }
    fun discardDirectoryDraft(id: String) = command { it.discardDirectoryDraft(id) }
    fun retryDirectoryWork(id: String) = command { it.retryDirectoryWork(id) }
    fun signOut() {
        if (mutable.value.busy) return
        val prior = operation
        mutable.value = mutable.value.copy(busy = true, snapshot = null, error = null,
            generation = mutable.value.generation + 1, exitPending = true)
        operation = owner.launch {
            withContext(NonCancellable) {
                prior?.cancelAndJoin(); foregroundJob?.cancelAndJoin(); foregroundJob = null
                lifecycleGate.withLock {
                    try {
                        val snapshot = client?.signOut()
                        mutable.value = mutable.value.copy(snapshot = snapshot, exitPending = false)
                    } catch (error: Exception) { handle(error) }
                    finally { mutable.value = mutable.value.copy(busy = false) }
                }
            }
        }
    }
    private fun handle(error: Exception) {
        if (error is CancellationException) return
        val message = when ((error as? SharedSdkException)?.reason) {
            SharedError.AuthenticationRequired -> "账号或密码不正确，或需要重新登录"
            SharedError.NetworkUnavailable -> "连接暂时不可用，请稍后重试"
            SharedError.StorageUnavailable -> "无法访问本机账户数据，请稍后重试"
            SharedError.InvalidConfiguration -> "请检查服务器地址和登录信息"
            SharedError.InvalidInput -> if (mutable.value.snapshot?.userID != null) "内容或权限已变化，请刷新后重试" else "请检查服务器地址和登录信息"
            else -> "操作未完成，请重试"
        }
        mutable.value = mutable.value.copy(error = message)
    }
    override fun onCleared() {
        operation?.cancel(); foregroundJob?.cancel(); readReportJob?.cancel()
        owner.launch {
            try {
                operation?.join(); foregroundJob?.join(); readReportJob?.join()
                lifecycleGate.withLock { client?.close(); client = null }
            } finally { owner.cancel() }
        }
    }
}
