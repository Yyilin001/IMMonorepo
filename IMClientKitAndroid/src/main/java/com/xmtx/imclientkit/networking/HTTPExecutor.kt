package com.xmtx.imclientkit.networking

import com.xmtx.imclientkit.services.EmptyResponse
import io.ktor.client.HttpClient
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.io.IOException

internal class HTTPExecutor(
    private val client: HttpClient,
    private val network: NetworkEnvironment,
    private val json: Json = JsonConfiguration.default,
) {
    internal suspend inline fun <reified Response : Any> execute(spec: HTTPRequestSpec): Response =
        execute(spec, accessToken = null)

    internal suspend inline fun <reified Response : Any> execute(
        spec: HTTPRequestSpec,
        accessToken: String?,
    ): Response {
        val response = try {
            request(spec, accessToken)
        } catch (error: APIError) {
            throw error
        } catch (error: IOException) {
            throw APIError.Network(error)
        } catch (error: Throwable) {
            throw APIError.Network(error)
        }

        return decodeResponse(response)
    }

    suspend fun request(spec: HTTPRequestSpec, accessToken: String? = null): HttpResponse =
        client.request(resolvedUrl(spec.path)) {
            method = spec.method
            spec.queryItems.forEach { item ->
                url.parameters.append(item.name, item.value)
            }
            header(HttpHeaders.Accept, ContentType.Application.Json.toString())
            if (accessToken != null) {
                bearerAuth(accessToken)
            }
            if (spec.body != null) {
                contentType(ContentType.Application.Json)
                setBody(spec.body)
            }
        }

    internal inline fun <reified Response : Any> decodeSuccess(text: String): Response {
        if (Response::class == EmptyResponse::class && text.isBlank()) {
            @Suppress("UNCHECKED_CAST")
            return EmptyResponse as Response
        }
        return try {
            json.decodeFromString(text)
        } catch (error: SerializationException) {
            throw APIError.Decoding(error)
        }
    }

    internal suspend inline fun <reified Response : Any> decodeResponse(response: HttpResponse): Response {
        val text = response.bodyAsText()
        if (response.status.isSuccess()) {
            return decodeSuccess(text)
        }

        if (response.status.value == 401) {
            throw APIError.AuthenticationExpired
        }

        val serverMessage = serverMessage(text) ?: response.status.description
        if (response.status.value >= 400) {
            throw APIError.Server(response.status.value, serverMessage)
        }
        throw APIError.UnexpectedStatus(response.status.value, text)
    }

    fun serverMessage(text: String): String? =
        runCatching {
            val envelope = json.decodeFromString<ServerErrorEnvelope>(text)
            envelope.message ?: envelope.reason ?: envelope.error
        }.getOrNull()

    fun resolvedUrl(path: String): String =
        network.apiBaseUrl.trimEnd('/') + "/" + path.trimStart('/')
}
