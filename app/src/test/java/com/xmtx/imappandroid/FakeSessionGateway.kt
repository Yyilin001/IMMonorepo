package com.xmtx.imappandroid

import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

class FakeSessionGateway(
    var restoreResult: RestoreResult = RestoreResult.SignedOut(),
    var loginResult: Result<AuthUser> = Result.success(AuthUser("user-1", "a@example.com")),
    var registerResult: Result<AuthUser> = Result.success(AuthUser("user-1", "a@example.com")),
    var conversationPageResult: Result<IMConversationSummaryPageResponseBody> = Result.success(emptyConversationPage()),
    var messagesResult: Result<List<IMConversationMessageResponseBody>> = Result.success(emptyList()),
) : IMSessionGateway {
    private val mutableConversationState = MutableStateFlow(ConversationListState())
    private val mutableSessionInvalidations = MutableSharedFlow<String>(extraBufferCapacity = 1)
    override val conversationState: StateFlow<ConversationListState> = mutableConversationState
    override val sessionInvalidations: SharedFlow<String> = mutableSessionInvalidations

    var didClearSession = false
    var didStopRuntime = false
    var startedRuntimeUserID: String? = null
    var openedConversationID: String? = null
    var sentText: Pair<String, String>? = null

    override suspend fun restoreSession(): RestoreResult = restoreResult

    override suspend fun login(email: String, password: String): AuthUser =
        loginResult.getOrThrow()

    override suspend fun register(email: String, password: String): AuthUser =
        registerResult.getOrThrow()

    override suspend fun clearSession() {
        didClearSession = true
    }

    override fun startIMRuntime(userID: String) {
        startedRuntimeUserID = userID
    }

    override fun stopIMRuntime() {
        didStopRuntime = true
    }

    override fun reloadConversations() {
        conversationPageResult.onSuccess { page ->
            mutableConversationState.value = ConversationListState(
                conversations = page.items.map { IMConversation(id = it.id, summary = it) },
                snapshotToken = page.snapshotToken,
                hasMore = page.hasMore,
                nextCursor = page.nextCursor,
            )
        }.onFailure { error ->
            mutableConversationState.value = ConversationListState(statusMessage = error.message)
        }
    }

    override fun openConversation(conversationID: String) {
        openedConversationID = conversationID
        mutableConversationState.value = mutableConversationState.value.copy(selectedConversationID = conversationID)
    }

    override fun sendText(text: String, conversationID: String) {
        sentText = text to conversationID
    }

    override suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody =
        conversationPageResult.getOrThrow()

    override suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody> =
        messagesResult.getOrThrow()

    suspend fun invalidateSession(message: String) {
        mutableSessionInvalidations.emit(message)
    }
}

fun emptyConversationPage(): IMConversationSummaryPageResponseBody =
    IMConversationSummaryPageResponseBody(
        items = emptyList(),
        hasMore = false,
        snapshotToken = "snapshot",
    )

fun conversation(id: String): IMConversationSummaryResponseBody =
    IMConversationSummaryResponseBody(
        id = id,
        title = "General",
        memberCount = 2,
        updatedAt = "2026-05-13T00:00:00Z",
    )
