package com.xmtx.imclientkit.networking

import kotlinx.serialization.Serializable

@Serializable
data class ServerErrorEnvelope(
    val error: String? = null,
    val reason: String? = null,
    val message: String? = null,
)
