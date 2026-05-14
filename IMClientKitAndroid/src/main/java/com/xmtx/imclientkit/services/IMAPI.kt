package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.features.im.IMConversationReadRequestBody
import com.xmtx.imclientkit.networking.HTTPQueryItem
import com.xmtx.imclientkit.networking.HTTPRequestSpec
import com.xmtx.imclientkit.networking.JsonConfiguration
import io.ktor.http.HttpMethod
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class IMAPI(
    private val json: Json = JsonConfiguration.default,
) {
    fun conversations(
        cursor: String? = null,
        limit: Int? = null,
        kind: IMConversationKind? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations",
            queryItems = listOfNotNull(
                cursor?.let { HTTPQueryItem("cursor", it) },
                limit?.let { HTTPQueryItem("limit", it.toString()) },
                kind?.let { HTTPQueryItem("kind", it.rawValue) },
            ),
        )

    fun messages(
        conversationID: String,
        beforeSequence: ULong? = null,
        limit: Int? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/messages",
            queryItems = listOfNotNull(
                beforeSequence?.let { HTTPQueryItem("beforeSequence", it.toString()) },
                limit?.let { HTTPQueryItem("limit", it.toString()) },
            ),
        )

    fun messagesSince(
        conversationID: String,
        afterSequence: ULong,
        limit: Int? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/messages/since",
            queryItems = listOfNotNull(
                HTTPQueryItem("afterSequence", afterSequence.toString()),
                limit?.let { HTTPQueryItem("limit", it.toString()) },
            ),
        )

    fun markRead(
        conversationID: String,
        readSequence: ULong,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/read",
            method = HttpMethod.Post,
            body = json.encodeToString(IMConversationReadRequestBody(readSequence)),
        )
}
