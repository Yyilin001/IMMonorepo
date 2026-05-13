package com.xmtx.imappandroid

import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.RestoreResult
import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody

class FakeSessionGateway(
    var restoreResult: RestoreResult = RestoreResult.SignedOut(),
    var loginResult: Result<AuthUser> = Result.success(AuthUser("user-1", "a@example.com")),
    var registerResult: Result<AuthUser> = Result.success(AuthUser("user-1", "a@example.com")),
    var conversationPageResult: Result<IMConversationSummaryPageResponseBody> = Result.success(emptyConversationPage()),
    var messagesResult: Result<List<IMConversationMessageResponseBody>> = Result.success(emptyList()),
) : IMSessionGateway {
    var didClearSession = false

    override suspend fun restoreSession(): RestoreResult = restoreResult

    override suspend fun login(email: String, password: String): AuthUser =
        loginResult.getOrThrow()

    override suspend fun register(email: String, password: String): AuthUser =
        registerResult.getOrThrow()

    override suspend fun clearSession() {
        didClearSession = true
    }

    override suspend fun fetchConversationSummaries(): IMConversationSummaryPageResponseBody =
        conversationPageResult.getOrThrow()

    override suspend fun fetchMessages(conversationID: String): List<IMConversationMessageResponseBody> =
        messagesResult.getOrThrow()
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
