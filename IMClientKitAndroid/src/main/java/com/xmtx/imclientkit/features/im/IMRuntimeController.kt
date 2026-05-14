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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlin.math.min

class IMRuntimeController(
    private val sessionClient: SessionClient,
    val conversationStore: IMConversationStore,
    private val configuration: IMTCPClientConfiguration,
    private val conversationCache: IMConversationCaching = NoopIMConversationCache(),
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
    private var cacheObserveJob: Job? = null
    private var cacheSaveJob: Job? = null
    private var reconnectAttempt = 0
    private val readReportJobs = mutableMapOf<String, Job>()
    private val pendingReadSequences = mutableMapOf<String, ULong>()

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
            refreshConversationSummaries()
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
        cacheObserveJob?.cancel()
        cacheObserveJob = null
        readReportJobs.values.forEach { it.cancel() }
        readReportJobs.clear()
        pendingReadSequences.clear()
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
                conversationStore.applyConversationSummary(event.payload.conversation)
                val userID = currentUserID
                val message = event.payload.message
                if (userID != null && message != null) {
                    conversationStore.appendMessages(message.conversationID, listOf(message), userID)
                }
            }
            is IMTCPConnectionEvent.ContactEvent -> Unit
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
        val current = pendingReadSequences[conversationID]
        pendingReadSequences[conversationID] = maxOf(current ?: 0UL, readSequence)
        readReportJobs[conversationID]?.cancel()
        readReportJobs[conversationID] = scope.launch {
            delay(READ_REPORT_DEBOUNCE_MILLIS)
            val sequence = pendingReadSequences.remove(conversationID) ?: return@launch
            runCatching {
                sessionClient.markIMConversationRead(conversationID, sequence)
            }.onSuccess { response ->
                conversationStore.applyServerExplicitReadResponse(response)
            }
        }
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
