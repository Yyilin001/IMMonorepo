package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ConversationListUiState(
    val conversations: List<IMConversationSummaryResponseBody> = emptyList(),
    val isLoading: Boolean = false,
    val message: String? = null,
)

class ConversationListViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ConversationListUiState())
    val state: StateFlow<ConversationListUiState> = mutableState

    fun loadConversations() {
        viewModelScope.launch {
            mutableState.update { it.copy(isLoading = true, message = null) }
            runCatching { gateway.fetchConversationSummaries() }
                .onSuccess { page ->
                    mutableState.value = ConversationListUiState(conversations = page.items)
                }
                .onFailure { error ->
                    mutableState.update {
                        it.copy(isLoading = false, message = error.message ?: "Failed to load conversations.")
                    }
                }
        }
    }
}
