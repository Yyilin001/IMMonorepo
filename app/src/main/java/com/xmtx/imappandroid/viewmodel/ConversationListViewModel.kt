package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.im.IMConnectionStatus
import com.xmtx.imclientkit.features.im.IMConversation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ConversationListUiState(
    val conversations: List<IMConversation> = emptyList(),
    val connectionStatus: IMConnectionStatus = IMConnectionStatus.Disconnected,
    val isLoading: Boolean = false,
    val message: String? = null,
)

class ConversationListViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ConversationListUiState())
    val state: StateFlow<ConversationListUiState> = mutableState

    init {
        viewModelScope.launch {
            gateway.conversationState.collect { storeState ->
                mutableState.value = ConversationListUiState(
                    conversations = storeState.conversations,
                    connectionStatus = storeState.connectionStatus,
                    message = storeState.statusMessage ?: storeState.connectionMessage,
                )
            }
        }
    }

    fun loadConversations() {
        mutableState.update { it.copy(isLoading = true, message = null) }
        gateway.reloadConversations()
        mutableState.update { it.copy(isLoading = false) }
    }
}
