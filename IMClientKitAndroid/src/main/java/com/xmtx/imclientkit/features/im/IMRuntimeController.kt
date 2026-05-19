package com.xmtx.imclientkit.features.im

import com.xmtx.imclientkit.SessionClient
import com.xmtx.imclientkit.networking.APIError
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientConfiguration
import com.xmtx.imclientkit.networking.imtcp.IMTCPClientError
import com.xmtx.imclientkit.networking.imtcp.IMTCPConnection
import com.xmtx.imclientkit.networking.imtcp.IMTCPConnectionEvent
import com.xmtx.imclientkit.networking.imtcp.IMTCPTransport
import com.xmtx.imclientkit.networking.imtcp.SocketIMTCPTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.min

class IMRuntimeController(
    private val sessionClient: SessionClient,
    val conversationStore: IMConversationStore,
    private val configuration: IMTCPClientConfiguration,
    private val conversationCache: IMConversationCaching = NoopIMConversationCache(),
    private val contactEventHandler: (() -> Unit)? = null,
    private val tcpTransport: IMTCPTransport = SocketIMTCPTransport(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private var currentUserID: String? = null
    private var connection: IMTCPConnection? = null
    private var connectJob: Job? = null
    private var eventJob: Job? = null
    private var reconnectJob: Job? = null
    private var gapSyncJob: Job? = null
    private var queuedFlushJob: Job? = null
    private var streamSnapshotWorkerJob: Job? = null
    private val streamSnapshotMutex = Mutex()
    private val pendingStreamSnapshotTargets = linkedSetOf<IMActiveMessageStreamTarget>()
    private val streamSnapshotRetryDelays = mutableMapOf<IMActiveMessageStreamTarget, Long>()
    private var cacheObserveJob: Job? = null
    private var cacheSaveJob: Job? = null
    private var reconnectAttempt = 0
    private val readReportJobs = mutableMapOf<String, Job>()

    private val mutableSessionInvalidations = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val sessionInvalidations: SharedFlow<String> = mutableSessionInvalidations

    fun start(userID: String) {
        if (currentUserID != null && currentUserID != userID) {
            stop()
        }
        currentUserID = userID
        reconnectAttempt = 0
        startCachePersistence(userID)
        scope.launch {
            restoreCachedSnapshot(userID)
            syncActiveStreamSnapshots()
            refreshConversationSummaries()
            syncActiveStreamSnapshots()
            retryPendingReadReports()
            scheduleConnectionIfNeeded()
        }
    }

    fun stop() {
        currentUserID = null
        reconnectAttempt = 0
        reconnectJob?.cancel()
        reconnectJob = null
        connectJob?.cancel()
        connectJob = null
        eventJob?.cancel()
        eventJob = null
        gapSyncJob?.cancel()
        gapSyncJob = null
        queuedFlushJob?.cancel()
        queuedFlushJob = null
        streamSnapshotWorkerJob?.cancel()
        streamSnapshotWorkerJob = null
        scope.launch {
            streamSnapshotMutex.withLock {
                pendingStreamSnapshotTargets.clear()
                streamSnapshotRetryDelays.clear()
            }
        }
        cacheObserveJob?.cancel()
        cacheObserveJob = null
        readReportJobs.values.forEach { it.cancel() }
        readReportJobs.clear()
        val currentConnection = connection
        connection = null
        conversationStore.setConnectionStatus(IMConnectionStatus.Disconnected)
        scope.launch { currentConnection?.disconnect() }
    }

    fun openConversation(conversationID: String) {
        conversationStore.openConversation(conversationID)
        scope.launch {
            loadMessages(conversationID)
            markConversationReadUpToLatestLoadedSequence(conversationID)
        }
    }

    fun reloadConversations() {
        scope.launch { refreshConversationSummaries() }
    }

    fun createConversation(kind: IMConversationKind, title: String?, memberEmails: List<String>) {
        scope.launch {
            runCatching {
                sessionClient.createIMConversation(kind = kind, title = title, memberEmails = memberEmails)
            }.onSuccess { summary ->
                conversationStore.applyConversationSummary(summary)
                conversationStore.openConversation(summary.id)
            }.onFailure { error ->
                conversationStore.setStatusMessage(error.message ?: "Failed to create conversation.")
            }
        }
    }

    fun loadMembers(conversationID: String, query: String? = null) {
        scope.launch {
            runCatching {
                sessionClient.fetchIMConversationMembers(conversationID, limit = DEFAULT_PAGE_LIMIT, query = query)
            }.onSuccess { page ->
                conversationStore.replaceMembers(conversationID, page)
            }.onFailure { error ->
                conversationStore.setStatusMessage(error.message ?: "Failed to load members.")
            }
        }
    }

    fun addMembers(conversationID: String, memberEmails: List<String>) {
        scope.launch {
            runCatching { sessionClient.addIMConversationMembers(conversationID, memberEmails) }
                .onSuccess {
                    conversationStore.applyConversationSummary(it)
                    loadMembers(conversationID)
                }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to add members.") }
        }
    }

    fun removeMember(conversationID: String, memberUserID: String) {
        scope.launch {
            runCatching { sessionClient.removeIMConversationMember(conversationID, memberUserID) }
                .onSuccess {
                    conversationStore.applyConversationSummary(it)
                    loadMembers(conversationID)
                }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to remove member.") }
        }
    }

    fun updateTitle(conversationID: String, title: String) {
        scope.launch {
            runCatching { sessionClient.updateIMConversationTitle(conversationID, title) }
                .onSuccess { conversationStore.applyConversationSummary(it) }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to update title.") }
        }
    }

    fun updatePreferences(conversationID: String, isPinned: Boolean? = null, isMuted: Boolean? = null) {
        scope.launch {
            runCatching { sessionClient.updateIMConversationPreferences(conversationID, isPinned, isMuted) }
                .onSuccess { conversationStore.applyConversationSummary(it) }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to update preferences.") }
        }
    }

    fun clearConversation(conversationID: String) {
        scope.launch {
            runCatching { sessionClient.clearIMConversationForSelf(conversationID) }
                .onSuccess { conversationStore.clearMessages(conversationID) }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to clear conversation.") }
        }
    }

    fun deleteConversation(conversationID: String) {
        scope.launch {
            runCatching { sessionClient.deleteIMConversationForSelf(conversationID) }
                .onSuccess { conversationStore.removeConversation(conversationID) }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to delete conversation.") }
        }
    }

    fun leaveConversation(conversationID: String) {
        scope.launch {
            runCatching { sessionClient.leaveIMConversation(conversationID) }
                .onSuccess { conversationStore.removeConversation(conversationID) }
                .onFailure { conversationStore.setStatusMessage(it.message ?: "Failed to leave conversation.") }
        }
    }

    suspend fun loadMessages(conversationID: String) {
        val userID = currentUserID ?: return
        runCatching {
            sessionClient.fetchIMMessages(conversationID = conversationID, limit = DEFAULT_PAGE_LIMIT)
        }.onSuccess { messages ->
            conversationStore.appendMessages(conversationID, messages, userID)
        }.onFailure { error ->
            conversationStore.setStatusMessage(error.message ?: "Failed to load messages.")
        }
    }

    fun sendText(text: String, conversationID: String) {
        val userID = currentUserID ?: return
        scope.launch {
            val currentConnection = connection
            if (currentConnection == null) {
                conversationStore.queueOutgoingText(text, conversationID, userID)
                scheduleConnectionIfNeeded()
                return@launch
            }

            val request = conversationStore.prepareOutgoingText(text, conversationID, userID) ?: return@launch
            runCatching {
                currentConnection.sendMessage(request.payload, request.requestID)
            }.onFailure {
                conversationStore.markFailed(request.localMessageID)
                handleConnectionFailure(it)
            }
        }
    }

    fun startAIReply(conversationID: String, prompt: String) {
        val userID = currentUserID ?: return
        scope.launch {
            runCatching {
                sessionClient.startAIMessageStream(conversationID, prompt)
            }.onSuccess { response ->
                conversationStore.applyMessageStreamSnapshot(response, userID)
                syncActiveStreamSnapshots()
            }.onFailure { error ->
                conversationStore.setStatusMessage(error.message ?: "Failed to start AI reply.")
            }
        }
    }

    fun cancelStream(conversationID: String, messageID: String) {
        val userID = currentUserID ?: return
        scope.launch {
            runCatching {
                sessionClient.cancelMessageStream(conversationID, messageID)
            }.onSuccess { response ->
                conversationStore.applyMessageStreamSnapshot(response, userID)
            }.onFailure { error ->
                conversationStore.setStatusMessage(error.message ?: "Failed to cancel stream.")
            }
        }
    }

    private suspend fun scheduleConnectionIfNeeded() {
        if (currentUserID == null || connection != null || connectJob != null) return
        reconnectJob?.cancel()
        reconnectJob = null
        conversationStore.setConnectionStatus(IMConnectionStatus.Connecting)
        connectJob = scope.launch {
            runCatching {
                sessionClient.openIMConnection(configuration, tcpTransport)
            }.onSuccess { nextConnection ->
                connectJob = null
                connection = nextConnection
                reconnectAttempt = 0
                conversationStore.setConnectionStatus(IMConnectionStatus.Connected)
                startEventLoop(nextConnection)
                flushQueuedTextMessages()
                syncConversationGapsAfterConnection()
                retryPendingReadReports()
                syncActiveStreamSnapshots()
            }.onFailure { error ->
                connectJob = null
                handleConnectionFailure(error)
            }
        }
    }

    private fun startCachePersistence(userID: String) {
        cacheObserveJob?.cancel()
        cacheObserveJob = scope.launch {
            var skippedInitial = false
            conversationStore.state.collect { state ->
                if (!skippedInitial) {
                    skippedInitial = true
                    return@collect
                }
                cacheSaveJob?.cancel()
                cacheSaveJob = scope.launch {
                    delay(CACHE_SAVE_DEBOUNCE_MILLIS)
                    runCatching {
                        conversationCache.saveSnapshot(userID, state)
                    }
                }
            }
        }
    }

    private suspend fun restoreCachedSnapshot(userID: String) {
        runCatching {
            conversationCache.loadSnapshot(userID)
        }.onSuccess { snapshot ->
            conversationStore.restoreSnapshot(snapshot ?: ConversationListState())
        }.onFailure {
            conversationStore.restoreSnapshot(ConversationListState())
        }
    }

    private fun startEventLoop(activeConnection: IMTCPConnection) {
        eventJob?.cancel()
        eventJob = scope.launch {
            runCatching {
                activeConnection.events.collect { event ->
                    handleConnectionEvent(event)
                }
                throw IMTCPClientError.ConnectionClosed
            }.onFailure { error ->
                if (connection === activeConnection) {
                    handleConnectionFailure(error)
                }
            }
        }
    }

    private suspend fun handleConnectionEvent(event: IMTCPConnectionEvent) {
        when (event) {
            is IMTCPConnectionEvent.HeartbeatAck -> Unit
            is IMTCPConnectionEvent.Ack -> conversationStore.applyOutgoingAcknowledgement(event.requestID, event.payload)
            is IMTCPConnectionEvent.Message -> handleIncomingMessage(event)
            is IMTCPConnectionEvent.ConversationEvent -> {
                val userID = currentUserID
                if (event.payload.eventType.startsWith("message_stream_") && userID != null) {
                    conversationStore.applyMessageStreamEvent(event.payload, userID)
                    syncPendingStreamSnapshotsIfNeeded()
                } else {
                    conversationStore.applyConversationSummary(event.payload.conversation)
                    val message = event.payload.message
                    if (userID != null && message != null) {
                        conversationStore.appendMessages(message.conversationID, listOf(message), userID)
                    }
                }
            }
            is IMTCPConnectionEvent.ContactEvent -> contactEventHandler?.invoke()
            is IMTCPConnectionEvent.Kick -> invalidateSession(event.payload.message)
        }
    }

    private suspend fun handleIncomingMessage(event: IMTCPConnectionEvent.Message) {
        val userID = currentUserID ?: return
        val payload = event.payload
        conversationStore.receiveIncomingMessage(payload, userID)
        val messageID = payload.messageID
        if (messageID != null) {
            connection?.sendAcknowledgement(
                IMTCPAckPayload(
                    messageID = messageID,
                    conversationID = payload.conversationID,
                    status = "received",
                ),
                requestID = event.requestID,
            )
        }
        if (
            payload.senderUserID != userID &&
            payload.conversationID == conversationStore.state.value.selectedConversationID &&
            payload.serverSequence != null
        ) {
            markConversationRead(payload.conversationID, payload.serverSequence)
        }
    }

    private suspend fun handleConnectionFailure(error: Throwable) {
        connectJob = null
        eventJob?.cancel()
        eventJob = null
        val oldConnection = connection
        connection = null
        oldConnection?.disconnect()

        when (error) {
            is IMTCPClientError.AuthRejected -> invalidateSession(error.serverMessage)
            is IMTCPClientError.Kicked -> invalidateSession(error.serverMessage)
            is APIError.AuthenticationExpired -> invalidateSession("Session expired.")
            else -> {
                conversationStore.markAllPendingMessagesUnknown("IM connection lost. Reconnecting.")
                conversationStore.setConnectionStatus(IMConnectionStatus.Failed, error.message)
                scheduleReconnectIfNeeded()
            }
        }
    }

    private suspend fun invalidateSession(message: String) {
        conversationStore.setConnectionStatus(IMConnectionStatus.Disconnected, message)
        mutableSessionInvalidations.emit(message)
        stop()
    }

    private fun scheduleReconnectIfNeeded() {
        if (currentUserID == null || reconnectJob != null) return
        val delayMillis = nextReconnectDelayMillis()
        reconnectJob = scope.launch {
            delay(delayMillis)
            reconnectJob = null
            scheduleConnectionIfNeeded()
        }
    }

    private fun nextReconnectDelayMillis(): Long {
        reconnectAttempt += 1
        val shift = min(reconnectAttempt - 1, 5)
        return min(RECONNECT_INITIAL_DELAY_MILLIS * (1L shl shift), RECONNECT_MAX_DELAY_MILLIS)
    }

    private suspend fun refreshConversationSummaries() {
        runCatching {
            sessionClient.fetchIMConversationSummaries(limit = DEFAULT_PAGE_LIMIT)
        }.onSuccess { page ->
            conversationStore.replaceSummaryWindow(page)
            retryPendingReadReports()
        }.onFailure { error ->
            conversationStore.setStatusMessage(error.message ?: "Failed to load conversations.")
        }
    }

    private fun syncConversationGapsAfterConnection() {
        gapSyncJob?.cancel()
        gapSyncJob = scope.launch {
            refreshConversationSummaries()
            val userID = currentUserID ?: return@launch
            for (conversationID in conversationStore.gapSyncTargets()) {
                syncConversationGap(conversationID, userID)
                markConversationReadUpToLatestLoadedSequence(conversationID)
            }
            syncActiveStreamSnapshots()
        }
    }

    private suspend fun syncConversationGap(conversationID: String, userID: String) {
        var afterSequence = conversationStore.latestLoadedServerSequence(conversationID) ?: return
        repeat(GAP_SYNC_MAX_ITERATIONS) {
            val response = sessionClient.fetchIMMessagesSince(
                conversationID = conversationID,
                afterSequence = afterSequence,
                limit = GAP_SYNC_LIMIT,
            )
            conversationStore.appendMessages(conversationID, response.messages, userID)
            if (!response.hasMore) return
            val next = response.nextAfterSequence?.toULong() ?: return
            if (next <= afterSequence) return
            afterSequence = next
        }
    }

    private fun flushQueuedTextMessages() {
        if (queuedFlushJob?.isActive == true) return
        queuedFlushJob = scope.launch {
            val activeConnection = connection ?: return@launch
            for (request in conversationStore.pendingQueuedTextRequests()) {
                conversationStore.markSending(request.localMessageID)
                runCatching {
                    activeConnection.sendMessage(request.payload, request.requestID)
                }.onFailure {
                    conversationStore.markFailed(request.localMessageID)
                    handleConnectionFailure(it)
                    return@launch
                }
            }
        }
    }

    private suspend fun markConversationReadUpToLatestLoadedSequence(conversationID: String) {
        val sequence = conversationStore.latestLoadedServerSequence(conversationID) ?: return
        markConversationRead(conversationID, sequence)
    }

    private fun markConversationRead(conversationID: String, readSequence: ULong) {
        conversationStore.recordPendingReadSequence(conversationID, readSequence)
        readReportJobs[conversationID]?.cancel()
        readReportJobs[conversationID] = scope.launch {
            delay(READ_REPORT_DEBOUNCE_MILLIS)
            val sequence = conversationStore.pendingReadSequences()[conversationID] ?: return@launch
            runCatching {
                sessionClient.markIMConversationRead(conversationID, sequence)
            }.onSuccess { response ->
                conversationStore.applyServerExplicitReadResponse(response)
                conversationStore.clearPendingReadSequence(conversationID, sequence)
            }
        }
    }

    private fun retryPendingReadReports() {
        conversationStore.pendingReadSequences().forEach { (conversationID, sequence) ->
            markConversationRead(conversationID, sequence)
        }
    }

    private fun syncPendingStreamSnapshotsIfNeeded() {
        val targets = conversationStore.consumePendingStreamSnapshotTargets()
        if (targets.isNotEmpty()) {
            enqueueStreamSnapshots(targets)
        }
    }

    private fun syncActiveStreamSnapshots() {
        val targets = conversationStore.activeMessageStreamTargets()
        if (targets.isNotEmpty()) {
            enqueueStreamSnapshots(targets)
        }
    }

    private fun enqueueStreamSnapshots(targets: List<IMActiveMessageStreamTarget>) {
        val userID = currentUserID ?: return
        val distinctTargets = targets.distinct()
        if (distinctTargets.isEmpty()) return
        scope.launch {
            streamSnapshotMutex.withLock {
                pendingStreamSnapshotTargets.addAll(distinctTargets)
            }
            startStreamSnapshotWorkerIfNeeded(userID)
        }
    }

    private fun startStreamSnapshotWorkerIfNeeded(userID: String) {
        if (streamSnapshotWorkerJob?.isActive == true) return
        streamSnapshotWorkerJob = scope.launch {
            while (currentUserID == userID) {
                val target = streamSnapshotMutex.withLock {
                    val next = pendingStreamSnapshotTargets.firstOrNull()
                    if (next != null) {
                        pendingStreamSnapshotTargets.remove(next)
                    }
                    next
                } ?: break

                val retryDelay = streamSnapshotMutex.withLock {
                    streamSnapshotRetryDelays[target] ?: 0L
                }
                if (retryDelay > 0L) {
                    delay(retryDelay)
                }
                if (currentUserID != userID) break

                try {
                    val response = sessionClient.fetchMessageStreamSnapshot(target.conversationID, target.messageID)
                    conversationStore.applyMessageStreamSnapshot(response, userID)
                    streamSnapshotMutex.withLock {
                        streamSnapshotRetryDelays.remove(target)
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    streamSnapshotMutex.withLock {
                        pendingStreamSnapshotTargets.add(target)
                        streamSnapshotRetryDelays[target] = nextStreamSnapshotRetryDelay(streamSnapshotRetryDelays[target])
                    }
                }
            }
            streamSnapshotWorkerJob = null
            val shouldRestart = streamSnapshotMutex.withLock { pendingStreamSnapshotTargets.isNotEmpty() }
            if (currentUserID == userID && shouldRestart) {
                startStreamSnapshotWorkerIfNeeded(userID)
            }
        }
    }

    private fun nextStreamSnapshotRetryDelay(current: Long?): Long =
        when (current) {
            null, 0L -> 1_000L
            1_000L -> 2_000L
            2_000L -> 5_000L
            5_000L -> 10_000L
            else -> 30_000L
        }

    private companion object {
        const val DEFAULT_PAGE_LIMIT = 50
        const val GAP_SYNC_LIMIT = 100
        const val GAP_SYNC_MAX_ITERATIONS = 10
        const val READ_REPORT_DEBOUNCE_MILLIS = 300L
        const val RECONNECT_INITIAL_DELAY_MILLIS = 1_000L
        const val RECONNECT_MAX_DELAY_MILLIS = 30_000L
        const val CACHE_SAVE_DEBOUNCE_MILLIS = 500L
    }
}
