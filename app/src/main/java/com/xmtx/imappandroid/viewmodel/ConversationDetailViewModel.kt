package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.im.IMConversationMessage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

data class ConversationDetailUiState(
    val conversationID: String? = null,
    val messages: List<IMConversationMessage> = emptyList(),
    val draftText: String = "",
    val isLoading: Boolean = false,
    val message: String? = null,
)

class ConversationDetailViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ConversationDetailUiState())
    val state: StateFlow<ConversationDetailUiState> = mutableState

    init {
        viewModelScope.launch {
            gateway.conversationState.collect { storeState ->
                val selected = storeState.selectedConversation
                mutableState.value = mutableState.value.copy(
                    conversationID = storeState.selectedConversationID,
                    messages = selected?.messages.orEmpty(),
                    message = storeState.statusMessage,
                    isLoading = false,
                )
            }
        }
    }

    fun openConversation(conversationID: String) {
        mutableState.value = mutableState.value.copy(isLoading = true)
        gateway.openConversation(conversationID)
    }

    fun updateDraft(text: String) {
        mutableState.value = mutableState.value.copy(draftText = text)
    }

    fun sendText() {
        val conversationID = state.value.conversationID ?: return
        val text = state.value.draftText
        if (text.isBlank()) return
        mutableState.value = mutableState.value.copy(draftText = "")
        gateway.sendText(text, conversationID)
    }
}
