package com.xmtx.imclientkit.features.im

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.time.Instant
import java.util.UUID

data class ConversationListState(
    val conversations: List<IMConversation> = emptyList(),
    val selectedConversationID: String? = null,
    val connectionStatus: IMConnectionStatus = IMConnectionStatus.Disconnected,
    val connectionMessage: String? = null,
    val nextCursor: String? = null,
    val hasMore: Boolean = false,
    val snapshotToken: String? = null,
    val lastSummaryRefreshAt: String? = null,
    val loadedConversationIDs: Set<String> = emptySet(),
    val latestSyncedServerSequences: Map<String, ULong> = emptyMap(),
    val oldestLoadedServerSequences: Map<String, ULong> = emptyMap(),
    val statusMessage: String? = null,
) {
    val selectedConversation: IMConversation?
        get() = conversations.firstOrNull { it.id == selectedConversationID }
}

class IMConversationStore {
    private val mutableState = MutableStateFlow(ConversationListState())
    val state: StateFlow<ConversationListState> = mutableState

    fun restoreSnapshot(snapshot: ConversationListState) {
        val selectedConversationID = snapshot.selectedConversationID?.takeIf { selected ->
            snapshot.conversations.any { it.id == selected }
        } ?: snapshot.conversations.firstOrNull()?.id
        mutableState.value = snapshot.copy(
            selectedConversationID = selectedConversationID,
            connectionStatus = IMConnectionStatus.Disconnected,
            connectionMessage = null,
            statusMessage = null,
        )
    }

    fun replaceSummaryWindow(page: IMConversationSummaryPageResponseBody) {
        mutableState.update { current ->
            val existingByID = current.conversations.associateBy { it.id }
            current.copy(
                conversations = page.items
                    .map { summary ->
                        existingByID[summary.id]?.copy(
                            summary = summary,
                            serverLastReadSequence = summary.lastReadSequence.toULong(),
                            serverUnreadCount = summary.unreadCount,
                        ) ?: IMConversation(id = summary.id, summary = summary)
                    }
                    .sortedByDescending { it.summary.updatedAt },
                selectedConversationID = current.selectedConversationID?.takeIf { selected ->
                    page.items.any { it.id == selected }
                } ?: current.selectedConversationID,
                nextCursor = page.nextCursor,
                hasMore = page.hasMore,
                snapshotToken = page.snapshotToken,
                lastSummaryRefreshAt = Instant.now().toString(),
                statusMessage = null,
            )
        }
    }

    fun appendSummaryWindow(page: IMConversationSummaryPageResponseBody) {
        mutableState.update { current ->
            val existingByID = current.conversations.associateBy { it.id }
            val mergedByID = (current.conversations + page.items.map { summary ->
                existingByID[summary.id]?.copy(summary = summary) ?: IMConversation(id = summary.id, summary = summary)
            }).associateBy { it.id }
            current.copy(
                conversations = mergedByID.values.sortedByDescending { it.summary.updatedAt },
                nextCursor = page.nextCursor,
                hasMore = page.hasMore,
                snapshotToken = page.snapshotToken,
                lastSummaryRefreshAt = Instant.now().toString(),
                statusMessage = null,
            )
        }
    }

    fun applyConversationSummary(summary: IMConversationSummaryResponseBody) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations
                    .upsertByID(summary.id) { existing ->
                        existing?.copy(summary = summary) ?: IMConversation(id = summary.id, summary = summary)
                    }
                    .sortedByDescending { it.summary.updatedAt },
            )
        }
    }

    fun removeConversation(id: String) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.filterNot { it.id == id },
                selectedConversationID = current.selectedConversationID.takeUnless { it == id },
                loadedConversationIDs = current.loadedConversationIDs - id,
                latestSyncedServerSequences = current.latestSyncedServerSequences - id,
                oldestLoadedServerSequences = current.oldestLoadedServerSequences - id,
            )
        }
    }

    fun openConversation(id: String) {
        mutableState.update { current ->
            current.copy(selectedConversationID = id, statusMessage = null)
        }
    }

    fun appendMessages(
        conversationID: String,
        messages: List<IMConversationMessageResponseBody>,
        currentUserID: String,
    ) {
        val mapped = messages.map { it.toConversationMessage(currentUserID) }
        appendDomainMessages(conversationID, mapped, markLoaded = true)
    }

    fun receiveIncomingMessage(payload: IMTCPMessagePayload, currentUserID: String) {
        appendDomainMessages(payload.conversationID, listOf(payload.toConversationMessage(currentUserID)))
    }

    fun prepareOutgoingText(
        text: String,
        conversationID: String,
        senderUserID: String,
    ): IMOutgoingMessageRequest? {
        val normalizedText = text.trim()
        if (normalizedText.isEmpty()) {
            setStatusMessage("Message cannot be empty.")
            return null
        }

        val requestID = UUID.randomUUID().toString()
        val localMessageID = UUID.randomUUID().toString()
        val clientMessageID = UUID.randomUUID().toString()
        val content = IMMessageContent.Text(normalizedText)
        val localMessage = IMConversationMessage(
            id = localMessageID,
            conversationID = conversationID,
            clientMessageID = clientMessageID,
            serverMessageID = null,
            senderUserID = senderUserID,
            serverSequence = null,
            content = content,
            direction = IMMessageDirection.Outgoing,
            createdAt = Instant.now().toString(),
            deliveryState = IMMessageDeliveryState.Sending,
        )
        appendDomainMessages(conversationID, listOf(localMessage))
        return IMOutgoingMessageRequest(
            requestID = requestID,
            localMessageID = localMessageID,
            payload = IMTCPMessagePayload(
                clientMessageID = clientMessageID,
                conversationID = conversationID,
                senderUserID = senderUserID,
                content = content,
            ),
        )
    }

    fun queueOutgoingText(
        text: String,
        conversationID: String,
        senderUserID: String,
    ): Boolean {
        val request = prepareOutgoingText(text, conversationID, senderUserID) ?: return false
        updateMessageDelivery(request.localMessageID, IMMessageDeliveryState.Queued)
        return true
    }

    fun applyOutgoingAcknowledgement(requestID: String?, payload: IMTCPAckPayload) {
        val messageID = payload.messageID
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (payload.conversationID != null && conversation.id != payload.conversationID) {
                        conversation
                    } else {
                        conversation.copy(
                            messages = conversation.messages.map { message ->
                                val matchesClient = message.clientMessageID == messageID
                                val matchesServer = message.serverMessageID == messageID || message.id == messageID
                                if (matchesClient || matchesServer) {
                                    message.copy(
                                        serverMessageID = messageID,
                                        deliveryState = IMMessageDeliveryState.Sent,
                                    )
                                } else {
                                    message
                                }
                            },
                        )
                    }
                },
            )
        }
    }

    fun markAllPendingMessagesUnknown(message: String) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    conversation.copy(
                        messages = conversation.messages.map { item ->
                            when (item.deliveryState) {
                                IMMessageDeliveryState.Sending -> item.copy(deliveryState = IMMessageDeliveryState.Unknown)
                                else -> item
                            }
                        },
                    )
                },
                statusMessage = message,
            )
        }
    }

    fun applyServerExplicitReadResponse(response: IMConversationReadResponseBody) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id == response.conversationID) {
                        conversation.copy(
                            serverLastReadSequence = response.lastReadSequence.toULong(),
                            serverUnreadCount = response.unreadCount,
                            localUnreadDelta = 0,
                        )
                    } else {
                        conversation
                    }
                },
            )
        }
    }

    fun latestLoadedServerSequence(conversationID: String): ULong? =
        state.value.latestSyncedServerSequences[conversationID]
            ?: state.value.conversations
            .firstOrNull { it.id == conversationID }
            ?.messages
            ?.mapNotNull { it.serverSequence }
            ?.maxOrNull()

    fun gapSyncTargets(): List<String> =
        state.value.conversations.mapNotNull { conversation ->
            val loaded = conversation.messages.mapNotNull { it.serverSequence }.maxOrNull()
            val summarySequence = conversation.summary.lastMessage?.serverSequence?.toULong()
            if (loaded != null && summarySequence != null && summarySequence > loaded) {
                conversation.id
            } else {
                null
            }
        }

    fun pendingQueuedTextRequests(): List<IMOutgoingMessageRequest> =
        state.value.conversations.flatMap { conversation ->
            conversation.messages
                .filter { it.deliveryState == IMMessageDeliveryState.Queued }
                .mapNotNull { message ->
                    message.clientMessageID?.let { clientMessageID ->
                        IMOutgoingMessageRequest(
                            requestID = UUID.randomUUID().toString(),
                            localMessageID = message.id,
                            payload = IMTCPMessagePayload(
                                clientMessageID = clientMessageID,
                                conversationID = message.conversationID,
                                senderUserID = message.senderUserID,
                                content = message.content,
                            ),
                        )
                    }
                }
        }

    fun markSending(localMessageID: String) {
        updateMessageDelivery(localMessageID, IMMessageDeliveryState.Sending)
    }

    fun markFailed(localMessageID: String) {
        updateMessageDelivery(localMessageID, IMMessageDeliveryState.Failed)
    }

    fun setConnectionStatus(status: IMConnectionStatus, message: String? = null) {
        mutableState.update { it.copy(connectionStatus = status, connectionMessage = message) }
    }

    fun setStatusMessage(message: String?) {
        mutableState.update { it.copy(statusMessage = message) }
    }

    private fun appendDomainMessages(
        conversationID: String,
        messages: List<IMConversationMessage>,
        markLoaded: Boolean = false,
    ) {
        if (messages.isEmpty() && !markLoaded) return
        mutableState.update { current ->
            val existing = current.conversations.firstOrNull { it.id == conversationID }
            val existingMessages = existing?.messages.orEmpty()
            val mergedMessages = if (messages.isEmpty()) {
                existingMessages
            } else {
                (existingMessages + messages)
                    .dedupeMessages()
                    .sortedWith(compareBy<IMConversationMessage> { it.serverSequence ?: ULong.MAX_VALUE }.thenBy { it.createdAt })
            }
            val serverSequences = mergedMessages.mapNotNull { it.serverSequence }
            val latest = serverSequences.maxOrNull()
            val oldest = serverSequences.minOrNull()
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id != conversationID) {
                        conversation
                    } else {
                        conversation.copy(messages = mergedMessages)
                    }
                },
                loadedConversationIDs = if (markLoaded) {
                    current.loadedConversationIDs + conversationID
                } else {
                    current.loadedConversationIDs
                },
                latestSyncedServerSequences = if (latest != null) {
                    current.latestSyncedServerSequences + (conversationID to latest)
                } else {
                    current.latestSyncedServerSequences
                },
                oldestLoadedServerSequences = if (markLoaded && oldest != null) {
                    current.oldestLoadedServerSequences + (conversationID to oldest)
                } else {
                    current.oldestLoadedServerSequences
                },
            )
        }
    }

    private fun updateMessageDelivery(localMessageID: String, state: IMMessageDeliveryState) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    conversation.copy(
                        messages = conversation.messages.map { message ->
                            if (message.id == localMessageID) message.copy(deliveryState = state) else message
                        },
                    )
                },
            )
        }
    }

    private fun List<IMConversation>.upsertByID(
        id: String,
        makeValue: (IMConversation?) -> IMConversation,
    ): List<IMConversation> {
        val existing = firstOrNull { it.id == id }
        val updated = makeValue(existing)
        return if (existing == null) {
            this + updated
        } else {
            map { if (it.id == id) updated else it }
        }
    }

    private fun List<IMConversationMessage>.dedupeMessages(): List<IMConversationMessage> {
        val result = linkedMapOf<String, IMConversationMessage>()
        for (message in this) {
            val key = message.serverMessageID ?: message.clientMessageID ?: message.id
            result[key] = message
        }
        return result.values.toList()
    }
}

interface IMConversationCaching {
    suspend fun loadSnapshot(userID: String): ConversationListState?
    suspend fun saveSnapshot(userID: String, snapshot: ConversationListState)
    suspend fun clear(userID: String)
    suspend fun clearSnapshot(userID: String) = clear(userID)
}

class NoopIMConversationCache : IMConversationCaching {
    override suspend fun loadSnapshot(userID: String): ConversationListState? = null
    override suspend fun saveSnapshot(userID: String, snapshot: ConversationListState) = Unit
    override suspend fun clear(userID: String) = Unit
}
