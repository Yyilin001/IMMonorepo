package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ConversationDetailUiState(
    val messages: List<IMConversationMessageResponseBody> = emptyList(),
    val isLoading: Boolean = false,
    val message: String? = null,
)

class ConversationDetailViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ConversationDetailUiState())
    val state: StateFlow<ConversationDetailUiState> = mutableState

    fun loadMessages(conversationID: String) {
        viewModelScope.launch {
            mutableState.update { it.copy(isLoading = true, message = null) }
            runCatching { gateway.fetchMessages(conversationID) }
                .onSuccess { messages ->
                    mutableState.value = ConversationDetailUiState(messages = messages.sortedBy { it.serverSequence })
                }
                .onFailure { error ->
                    mutableState.update {
                        it.copy(isLoading = false, message = error.message ?: "Failed to load messages.")
                    }
                }
        }
    }
}
