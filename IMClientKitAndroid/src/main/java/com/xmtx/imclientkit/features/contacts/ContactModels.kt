package com.xmtx.imclientkit.features.contacts

import com.xmtx.imclientkit.auth.AuthUser
import kotlinx.serialization.Serializable

enum class ContactRequestBox(val rawValue: String) {
    Incoming("incoming"),
    Outgoing("outgoing"),
    All("all"),
}

@Serializable
enum class ContactRequestStatus {
    pending,
    accepted,
    declined,
    cancelled,
}

@Serializable
data class ContactCreateRequestBody(
    val email: String,
    val remark: String? = null,
)

@Serializable
data class ContactUpdateRequestBody(
    val remark: String? = null,
)

@Serializable
data class ContactRequestCreateRequestBody(
    val email: String,
    val message: String? = null,
    val remark: String? = null,
)

@Serializable
data class ContactRequestAcceptRequestBody(
    val remark: String? = null,
)

@Serializable
data class ContactResponseBody(
    val id: String,
    val email: String,
    val displayName: String? = null,
    val avatarPreset: String? = null,
    val remark: String? = null,
    val createdAt: String? = null,
) {
    val preferredDisplayName: String
        get() = remark?.trim()?.takeIf { it.isNotEmpty() }
            ?: displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: email
}

@Serializable
data class ContactRequestResponseBody(
    val id: String,
    val requester: AuthUser,
    val addressee: AuthUser,
    val status: ContactRequestStatus,
    val message: String? = null,
    val requesterRemark: String? = null,
    val addresseeRemark: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
    val respondedAt: String? = null,
) {
    fun peerUser(currentUserID: String?): AuthUser =
        if (requester.id == currentUserID) addressee else requester

    fun peerDisplayName(currentUserID: String?): String =
        peerUser(currentUserID).preferredDisplayName
}

data class ContactState(
    val contacts: List<ContactResponseBody> = emptyList(),
    val incomingRequests: List<ContactRequestResponseBody> = emptyList(),
    val outgoingRequests: List<ContactRequestResponseBody> = emptyList(),
    val resolvedRequests: List<ContactRequestResponseBody> = emptyList(),
    val isLoading: Boolean = false,
    val statusMessage: String? = null,
)

interface ContactStateCaching {
    suspend fun loadSnapshot(userID: String): ContactState?
    suspend fun saveSnapshot(userID: String, snapshot: ContactState)
    suspend fun clear(userID: String)
}

class NoopContactStateCache : ContactStateCaching {
    override suspend fun loadSnapshot(userID: String): ContactState? = null
    override suspend fun saveSnapshot(userID: String, snapshot: ContactState) = Unit
    override suspend fun clear(userID: String) = Unit
}
