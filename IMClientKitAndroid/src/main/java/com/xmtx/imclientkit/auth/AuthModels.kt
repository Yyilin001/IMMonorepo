package com.xmtx.imclientkit.auth

import kotlinx.serialization.Serializable

@Serializable
data class AuthUser(
    val id: String,
    val email: String,
    val displayName: String? = null,
    val avatarPreset: String? = null,
) {
    val preferredDisplayName: String
        get() = displayName?.trim()?.takeIf { it.isNotEmpty() } ?: email
}

@Serializable
data class DeviceMetadataPayload(
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = "android",
    val appVersion: String? = null,
)

@Serializable
data class CredentialsRequestBody(
    val email: String,
    val password: String,
    val device: DeviceMetadataPayload? = null,
)

@Serializable
data class RefreshRequestBody(
    val refreshToken: String,
)

@Serializable
data class AuthResponseBody(
    val accessToken: String,
    val expiresIn: Int,
    val refreshToken: String,
    val refreshExpiresIn: Int,
    val user: AuthUser,
)

@Serializable
data class SessionSnapshot(
    val id: String,
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = null,
    val appVersion: String? = null,
    val lastSeenAt: String? = null,
    val createdAt: String? = null,
    val refreshExpiresAt: String,
    val isCurrent: Boolean,
)

sealed interface RestoreResult {
    data class Authenticated(val user: AuthUser) : RestoreResult
    data class SignedOut(val message: String? = null) : RestoreResult
}
