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
    val pendingReadSequences: Map<String, ULong> = emptyMap(),
    val statusMessage: String? = null,
) {
    val selectedConversation: IMConversation?
        get() = conversations.firstOrNull { it.id == selectedConversationID }
}

class IMConversationStore {
    private val mutableState = MutableStateFlow(ConversationListState())
    private val pendingRequestLocalMessageIDs = mutableMapOf<String, String>()
    private val pendingStreamSnapshotTargets = mutableSetOf<IMActiveMessageStreamTarget>()
    val state: StateFlow<ConversationListState> = mutableState

    fun restoreSnapshot(snapshot: ConversationListState) {
        pendingRequestLocalMessageIDs.clear()
        pendingStreamSnapshotTargets.clear()
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
                existingByID[summary.id]?.copy(
                    summary = summary,
                    serverLastReadSequence = summary.lastReadSequence.toULong(),
                    serverUnreadCount = summary.unreadCount,
                    localUnreadDelta = 0,
                ) ?: IMConversation(id = summary.id, summary = summary)
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
                        existing?.copy(
                            summary = summary,
                            serverLastReadSequence = summary.lastReadSequence.toULong(),
                            serverUnreadCount = summary.unreadCount,
                            localUnreadDelta = 0,
                        ) ?: IMConversation(id = summary.id, summary = summary)
                    }
                    .sortedByDescending { it.summary.updatedAt },
            )
        }
    }

    fun replaceMembers(conversationID: String, page: IMConversationMemberPageResponseBody) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id == conversationID) {
                        conversation.copy(
                            members = page.items.sortedBy { it.preferredDisplayName.lowercase() },
                            membersNextCursor = page.nextCursor,
                            hasMoreMembers = page.hasMore,
                        )
                    } else {
                        conversation
                    }
                },
            )
        }
    }

    fun appendMembers(conversationID: String, page: IMConversationMemberPageResponseBody) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id == conversationID) {
                        val members = (conversation.members + page.items)
                            .associateBy { it.id }
                            .values
                            .sortedBy { it.preferredDisplayName.lowercase() }
                        conversation.copy(
                            members = members,
                            membersNextCursor = page.nextCursor,
                            hasMoreMembers = page.hasMore,
                        )
                    } else {
                        conversation
                    }
                },
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

    fun clearMessages(conversationID: String) {
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id == conversationID) conversation.copy(messages = emptyList()) else conversation
                },
                latestSyncedServerSequences = current.latestSyncedServerSequences - conversationID,
                oldestLoadedServerSequences = current.oldestLoadedServerSequences - conversationID,
                loadedConversationIDs = current.loadedConversationIDs - conversationID,
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

    fun applyMessageStreamEvent(payload: IMTCPConversationEventPayload, currentUserID: String) {
        applyConversationSummary(payload.conversation)
        payload.message?.let { appendMessages(it.conversationID, listOf(it), currentUserID) }
        val stream = payload.stream ?: return
        val incomingState = IMMessageStreamLifecycleState.from(stream.state) ?: return
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (conversation.id != stream.conversationID) {
                        conversation
                    } else {
                        conversation.copy(
                            messages = conversation.messages.map { message ->
                                val existingState = message.streamState
                                val existingStreamID = existingState?.streamID
                                val existingChunkIndex = existingState?.lastChunkIndex ?: 0
                                val matches = message.id == stream.messageID ||
                                    message.serverMessageID == stream.messageID ||
                                    existingStreamID == stream.streamID
                                if (!matches || (existingState?.state?.isTerminal == true && incomingState == IMMessageStreamLifecycleState.Streaming)) {
                                    message
                                } else if (incomingState == IMMessageStreamLifecycleState.Streaming && stream.chunkIndex <= existingChunkIndex) {
                                    message
                                } else if (incomingState == IMMessageStreamLifecycleState.Streaming && stream.chunkIndex > existingChunkIndex + 1) {
                                    pendingStreamSnapshotTargets += IMActiveMessageStreamTarget(
                                        conversationID = stream.conversationID,
                                        messageID = stream.messageID,
                                        streamID = stream.streamID,
                                    )
                                    message
                                } else if (incomingState == IMMessageStreamLifecycleState.Streaming && existingState == null && stream.chunkIndex > 1) {
                                    pendingStreamSnapshotTargets += IMActiveMessageStreamTarget(
                                        conversationID = stream.conversationID,
                                        messageID = stream.messageID,
                                        streamID = stream.streamID,
                                    )
                                    message
                                } else {
                                    val existingText = (message.content as? IMMessageContent.Text)?.text.orEmpty()
                                    val nextText = if (incomingState == IMMessageStreamLifecycleState.Streaming) {
                                        existingText + stream.deltaText.orEmpty()
                                    } else {
                                        existingText
                                    }
                                    message.copy(
                                        content = IMMessageContent.Text(nextText),
                                        derivedState = message.derivedState.withMessageStreamState(
                                            IMMessageStreamState(
                                                streamID = stream.streamID,
                                                state = incomingState,
                                                lastChunkIndex = stream.chunkIndex,
                                                partialText = nextText,
                                                updatedAt = stream.serverTimestamp,
                                            ),
                                        ),
                                    )
                                }
                            },
                        )
                    }
                },
            )
        }
    }

    fun applyMessageStreamSnapshot(response: IMMessageStreamResponseBody, currentUserID: String) {
        appendMessages(response.message.conversationID, listOf(response.message), currentUserID)
        pendingStreamSnapshotTargets.remove(
            IMActiveMessageStreamTarget(
                conversationID = response.message.conversationID,
                messageID = response.message.id,
                streamID = response.stream.streamID,
            ),
        )
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
        pendingRequestLocalMessageIDs[requestID] = localMessageID
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
        val localMessageID = requestID?.let { pendingRequestLocalMessageIDs.remove(it) }
        val accepted = payload.status == "accepted"
        val failureMessage = if (accepted) null else outgoingAcknowledgementFailureMessage(payload.status)
        var didApplyFailure = false
        mutableState.update { current ->
            current.copy(
                conversations = current.conversations.map { conversation ->
                    if (payload.conversationID != null && conversation.id != payload.conversationID) {
                        conversation
                    } else {
                        conversation.copy(
                            messages = conversation.messages.map { message ->
                                val matchesRequest = localMessageID != null && message.id == localMessageID
                                val matchesClient = message.clientMessageID == messageID
                                val matchesServer = message.serverMessageID == messageID || message.id == messageID
                                if (matchesRequest || matchesClient || matchesServer) {
                                    if (!accepted && message.deliveryState == IMMessageDeliveryState.Sent) {
                                        message
                                    } else {
                                        if (!accepted) didApplyFailure = true
                                        message.copy(
                                            serverMessageID = message.serverMessageID ?: messageID,
                                            deliveryState = if (accepted) {
                                                IMMessageDeliveryState.Sent
                                            } else {
                                                IMMessageDeliveryState.Failed
                                            },
                                        )
                                    }
                                } else {
                                    message
                                }
                            },
                        )
                    }
                },
                statusMessage = if (didApplyFailure) failureMessage else current.statusMessage,
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

    fun recordPendingReadSequence(conversationID: String, readSequence: ULong) {
        mutableState.update { current ->
            val currentSequence = current.pendingReadSequences[conversationID]
            current.copy(
                pendingReadSequences = current.pendingReadSequences +
                    (conversationID to maxOf(currentSequence ?: 0UL, readSequence)),
            )
        }
    }

    fun clearPendingReadSequence(conversationID: String, readSequence: ULong) {
        mutableState.update { current ->
            val currentSequence = current.pendingReadSequences[conversationID]
            if (currentSequence != null && currentSequence <= readSequence) {
                current.copy(pendingReadSequences = current.pendingReadSequences - conversationID)
            } else {
                current
            }
        }
    }

    fun pendingReadSequences(): Map<String, ULong> = state.value.pendingReadSequences

    fun activeMessageStreamTargets(): List<IMActiveMessageStreamTarget> =
        state.value.conversations.flatMap { conversation ->
            conversation.messages.mapNotNull { message ->
                val streamState = message.streamState
                if (streamState?.state == IMMessageStreamLifecycleState.Streaming) {
                    IMActiveMessageStreamTarget(
                        conversationID = conversation.id,
                        messageID = message.serverMessageID ?: message.id,
                        streamID = streamState.streamID,
                    )
                } else {
                    null
                }
            }
        }.distinct()

    fun consumePendingStreamSnapshotTargets(): List<IMActiveMessageStreamTarget> {
        if (pendingStreamSnapshotTargets.isEmpty()) return emptyList()
        val targets = pendingStreamSnapshotTargets.toList()
        pendingStreamSnapshotTargets.clear()
        return targets
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
                        val requestID = UUID.randomUUID().toString()
                        pendingRequestLocalMessageIDs[requestID] = message.id
                        IMOutgoingMessageRequest(
                            requestID = requestID,
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
        val result = mutableListOf<IMConversationMessage>()
        for (message in this) {
            val existingIndex = result.indexOfFirst { existing ->
                existing.id == message.id ||
                    (existing.serverMessageID != null && existing.serverMessageID == message.serverMessageID) ||
                    (existing.clientMessageID != null && existing.clientMessageID == message.clientMessageID)
            }
            if (existingIndex >= 0) {
                result[existingIndex] = result[existingIndex].mergedWith(message)
            } else {
                result.add(message)
            }
        }
        return result
    }

    private fun IMConversationMessage.mergedWith(next: IMConversationMessage): IMConversationMessage =
        copy(
            id = next.serverMessageID ?: next.id,
            clientMessageID = next.clientMessageID ?: clientMessageID,
            serverMessageID = next.serverMessageID ?: serverMessageID,
            serverSequence = next.serverSequence ?: serverSequence,
            content = next.content,
            derivedState = next.derivedState,
            createdAt = next.createdAt,
            deliveryState = if (next.serverMessageID != null || next.serverSequence != null) {
                next.deliveryState
            } else {
                deliveryState
            },
            direction = next.direction,
            senderUserID = next.senderUserID,
        )

    private fun outgoingAcknowledgementFailureMessage(status: String): String =
        when (status) {
            "invalid_conversation_id" -> "Conversation is invalid."
            "conversation_unavailable" -> "Conversation is unavailable."
            "unsupported_message_content" -> "Message content is not supported."
            "empty_text_body" -> "Message cannot be empty."
            "invalid_reply_reference" -> "Reply target is invalid."
            "direct_conversation_frozen" -> "This conversation cannot receive messages."
            "stranger_direct_message_limit_reached" -> "Message limit reached before the peer replies."
            "hot_conversation_rate_limited" -> "Messages are too frequent. Try again later."
            "message_write_queue_full" -> "Message queue is busy. Try again later."
            "internal_error" -> "Message failed to send."
            else -> "Message failed to send."
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
