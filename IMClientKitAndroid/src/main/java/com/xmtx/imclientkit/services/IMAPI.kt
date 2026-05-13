package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.networking.HTTPQueryItem
import com.xmtx.imclientkit.networking.HTTPRequestSpec

class IMAPI {
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
}
