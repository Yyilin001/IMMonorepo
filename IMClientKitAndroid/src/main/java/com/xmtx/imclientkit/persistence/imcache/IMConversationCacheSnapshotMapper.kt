package com.xmtx.imclientkit.persistence.imcache

import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConnectionStatus
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationMessage
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState

data class IMCacheMetadataState(
    val selectedConversationID: String?,
    val lastSummaryRefreshAt: String?,
    val summarySyncToken: String?,
    val summaryNextCursor: String?,
    val hasMoreConversationSummaries: Boolean,
)

data class IMSyncCursorState(
    val conversationID: String,
    val hasLoadedMessages: Boolean,
    val latestSyncedServerSequence: ULong?,
    val oldestLoadedServerSequence: ULong?,
    val pendingReadSequence: ULong?,
)

data class IMConversationCacheSnapshot(
    val metadata: IMCacheMetadataState,
    val conversations: List<IMCachedConversationState>,
    val cursors: List<IMSyncCursorState>,
) {
    companion object {
        const val CACHED_MESSAGE_LIMIT = 200
        val Empty = IMConversationCacheSnapshot(
            metadata = IMCacheMetadataState(
                selectedConversationID = null,
                lastSummaryRefreshAt = null,
                summarySyncToken = null,
                summaryNextCursor = null,
                hasMoreConversationSummaries = false,
            ),
            conversations = emptyList(),
            cursors = emptyList(),
        )
    }
}

data class IMCachedConversationState(
    val conversation: IMConversation,
    val messages: List<IMConversationMessage>,
)

object IMConversationCacheSnapshotMapper {
    fun makeSnapshot(
        state: ConversationListState,
        messageLimit: Int = IMConversationCacheSnapshot.CACHED_MESSAGE_LIMIT,
    ): IMConversationCacheSnapshot {
        val cachedConversations = state.conversations.map { conversation ->
            val messages = conversation.messages
                .sortedWith(compareBy<IMConversationMessage> { it.serverSequence ?: ULong.MAX_VALUE }.thenBy { it.createdAt })
                .takeLast(messageLimit)
            IMCachedConversationState(
                conversation = conversation.copy(messages = messages),
                messages = messages,
            )
        }
        val cursors = cachedConversations.map { cached ->
            val conversationID = cached.conversation.id
            val sequences = cached.messages.mapNotNull { it.serverSequence }
            IMSyncCursorState(
                conversationID = conversationID,
                hasLoadedMessages = state.loadedConversationIDs.contains(conversationID),
                latestSyncedServerSequence = state.latestSyncedServerSequences[conversationID] ?: sequences.maxOrNull(),
                oldestLoadedServerSequence = state.oldestLoadedServerSequences[conversationID]
                    ?: sequences.minOrNull()?.takeIf { state.loadedConversationIDs.contains(conversationID) },
                pendingReadSequence = state.pendingReadSequences[conversationID],
            )
        }
        return IMConversationCacheSnapshot(
            metadata = IMCacheMetadataState(
                selectedConversationID = state.selectedConversationID,
                lastSummaryRefreshAt = state.lastSummaryRefreshAt,
                summarySyncToken = state.snapshotToken,
                summaryNextCursor = state.nextCursor,
                hasMoreConversationSummaries = state.hasMore,
            ),
            conversations = cachedConversations,
            cursors = cursors,
        )
    }

    fun restore(snapshot: IMConversationCacheSnapshot): ConversationListState {
        val cursorsByConversationID = snapshot.cursors.associateBy { it.conversationID }
        val conversations = snapshot.conversations.map { cached ->
            cached.conversation.copy(
                messages = cached.messages.map { message ->
                    message.copy(
                        deliveryState = when (message.deliveryState) {
                            IMMessageDeliveryState.Sending -> IMMessageDeliveryState.Unknown
                            else -> message.deliveryState
                        },
                    )
                },
            )
        }
        val selectedConversationID = snapshot.metadata.selectedConversationID?.takeIf { selected ->
            conversations.any { it.id == selected }
        } ?: conversations.firstOrNull()?.id
        return ConversationListState(
            conversations = conversations,
            selectedConversationID = selectedConversationID,
            connectionStatus = IMConnectionStatus.Disconnected,
            connectionMessage = null,
            nextCursor = snapshot.metadata.summaryNextCursor,
            hasMore = snapshot.metadata.hasMoreConversationSummaries,
            snapshotToken = snapshot.metadata.summarySyncToken,
            lastSummaryRefreshAt = snapshot.metadata.lastSummaryRefreshAt,
            loadedConversationIDs = snapshot.cursors
                .filter { it.hasLoadedMessages }
                .map { it.conversationID }
                .toSet(),
            latestSyncedServerSequences = cursorsByConversationID.mapNotNull { (conversationID, cursor) ->
                cursor.latestSyncedServerSequence?.let { conversationID to it }
            }.toMap(),
            oldestLoadedServerSequences = cursorsByConversationID.mapNotNull { (conversationID, cursor) ->
                cursor.oldestLoadedServerSequence?.let { conversationID to it }
            }.toMap(),
            pendingReadSequences = cursorsByConversationID.mapNotNull { (conversationID, cursor) ->
                cursor.pendingReadSequence?.let { conversationID to it }
            }.toMap(),
            statusMessage = null,
        )
    }
}
