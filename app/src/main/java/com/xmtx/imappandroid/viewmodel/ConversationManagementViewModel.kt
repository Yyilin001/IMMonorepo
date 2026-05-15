package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

data class ConversationManagementUiState(
    val selectedConversation: IMConversation? = null,
    val title: String = "",
    val memberEmails: String = "",
    val statusMessage: String? = null,
)

class ConversationManagementViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(ConversationManagementUiState())
    val state: StateFlow<ConversationManagementUiState> = mutableState

    init {
        viewModelScope.launch {
            gateway.conversationState.collect { storeState ->
                mutableState.value = mutableState.value.copy(
                    selectedConversation = storeState.selectedConversation,
                    title = storeState.selectedConversation?.displayTitle ?: mutableState.value.title,
                    statusMessage = storeState.statusMessage,
                )
            }
        }
    }

    fun updateTitle(title: String) {
        mutableState.value = mutableState.value.copy(title = title)
    }

    fun updateMemberEmails(value: String) {
        mutableState.value = mutableState.value.copy(memberEmails = value)
    }

    fun createGroup() {
        val emails = parsedEmails()
        if (emails.isEmpty()) return
        gateway.createConversation(IMConversationKind.Group, state.value.title.trim().takeIf { it.isNotEmpty() }, emails)
        mutableState.value = mutableState.value.copy(memberEmails = "")
    }

    fun loadMembers() {
        val conversationID = state.value.selectedConversation?.id ?: return
        gateway.loadConversationMembers(conversationID)
    }

    fun addMembers() {
        val conversationID = state.value.selectedConversation?.id ?: return
        val emails = parsedEmails()
        if (emails.isEmpty()) return
        gateway.addConversationMembers(conversationID, emails)
        mutableState.value = mutableState.value.copy(memberEmails = "")
    }

    fun saveTitle() {
        val conversationID = state.value.selectedConversation?.id ?: return
        val title = state.value.title.trim()
        if (title.isEmpty()) return
        gateway.updateConversationTitle(conversationID, title)
    }

    fun togglePinned() {
        val conversation = state.value.selectedConversation ?: return
        gateway.updateConversationPreferences(conversation.id, isPinned = !conversation.summary.isPinned, isMuted = null)
    }

    fun toggleMuted() {
        val conversation = state.value.selectedConversation ?: return
        gateway.updateConversationPreferences(conversation.id, isPinned = null, isMuted = !conversation.summary.isMuted)
    }

    fun clearConversation() {
        state.value.selectedConversation?.id?.let(gateway::clearConversation)
    }

    fun leaveConversation() {
        state.value.selectedConversation?.id?.let(gateway::leaveConversation)
    }

    fun deleteConversation() {
        state.value.selectedConversation?.id?.let(gateway::deleteConversation)
    }

    private fun parsedEmails(): List<String> =
        state.value.memberEmails
            .split(',', '\n', ' ')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
}
