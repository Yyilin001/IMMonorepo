package com.xmtx.imclientkit.networking

import io.ktor.http.HttpMethod

data class HTTPQueryItem(
    val name: String,
    val value: String,
)

data class HTTPRequestSpec(
    val path: String,
    val method: HttpMethod = HttpMethod.Get,
    val queryItems: List<HTTPQueryItem> = emptyList(),
    val body: String? = null,
)
