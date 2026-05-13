package com.xmtx.imclientkit.features.im

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

data class ConversationListState(
    val conversations: List<IMConversationSummaryResponseBody> = emptyList(),
    val nextCursor: String? = null,
    val hasMore: Boolean = false,
    val snapshotToken: String? = null,
    val statusMessage: String? = null,
)

class IMConversationStore {
    private val mutableState = MutableStateFlow(ConversationListState())
    val state: StateFlow<ConversationListState> = mutableState

    fun replaceSummaryWindow(page: IMConversationSummaryPageResponseBody) {
        mutableState.value = ConversationListState(
            conversations = page.items.sortedByDescending { it.updatedAt },
            nextCursor = page.nextCursor,
            hasMore = page.hasMore,
            snapshotToken = page.snapshotToken,
        )
    }

    fun appendSummaryWindow(page: IMConversationSummaryPageResponseBody) {
        mutableState.update { current ->
            val byId = (current.conversations + page.items)
                .associateBy { it.id }
                .values
                .sortedByDescending { it.updatedAt }
            current.copy(
                conversations = byId,
                nextCursor = page.nextCursor,
                hasMore = page.hasMore,
                snapshotToken = page.snapshotToken,
                statusMessage = null,
            )
        }
    }

    fun setStatusMessage(message: String?) {
        mutableState.update { it.copy(statusMessage = message) }
    }
}

interface IMConversationCaching {
    suspend fun loadSnapshot(userID: String): ConversationListState?
    suspend fun saveSnapshot(userID: String, snapshot: ConversationListState)
    suspend fun clearSnapshot(userID: String)
}

class NoopIMConversationCache : IMConversationCaching {
    override suspend fun loadSnapshot(userID: String): ConversationListState? = null
    override suspend fun saveSnapshot(userID: String, snapshot: ConversationListState) = Unit
    override suspend fun clearSnapshot(userID: String) = Unit
}
