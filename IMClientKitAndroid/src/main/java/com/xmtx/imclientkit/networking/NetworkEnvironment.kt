package com.xmtx.imclientkit.networking

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json

data class NetworkEnvironment(
    val apiBaseUrl: String,
    val imTcpHost: String,
    val imTcpPort: Int,
) {
    fun makeHttpClient(json: Json = JsonConfiguration.default): HttpClient =
        HttpClient(OkHttp) {
            expectSuccess = false
            install(ContentNegotiation) {
                json(json)
            }
        }
}

object JsonConfiguration {
    @OptIn(ExperimentalSerializationApi::class)
    val default: Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        isLenient = true
        encodeDefaults = true
        classDiscriminator = "type"
    }
}
