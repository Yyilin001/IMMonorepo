package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.auth.CredentialsRequestBody
import com.xmtx.imclientkit.auth.RefreshRequestBody
import com.xmtx.imclientkit.networking.HTTPRequestSpec
import com.xmtx.imclientkit.networking.JsonConfiguration
import io.ktor.http.HttpMethod
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class AuthAPI(
    private val json: Json = JsonConfiguration.default,
) {
    fun login(email: String, password: String, device: com.xmtx.imclientkit.auth.DeviceMetadataPayload?): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/auth/login",
            method = HttpMethod.Post,
            body = json.encodeToString(CredentialsRequestBody(email, password, device)),
        )

    fun register(email: String, password: String, device: com.xmtx.imclientkit.auth.DeviceMetadataPayload?): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/auth/register",
            method = HttpMethod.Post,
            body = json.encodeToString(CredentialsRequestBody(email, password, device)),
        )

    fun refresh(refreshToken: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/auth/refresh",
            method = HttpMethod.Post,
            body = json.encodeToString(RefreshRequestBody(refreshToken)),
        )

    fun sessions(): HTTPRequestSpec = HTTPRequestSpec(path = "api/auth/sessions")
}
