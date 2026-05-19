package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.features.im.IMConversationKind
import com.xmtx.imclientkit.features.im.IMConversationCreateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationMemberRole
import com.xmtx.imclientkit.features.im.IMConversationMemberRoleUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationMemberSelfUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationMemberUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationMetadataUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationPreferencesUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMConversationReadRequestBody
import com.xmtx.imclientkit.features.im.IMConversationTitleUpdateRequestBody
import com.xmtx.imclientkit.features.im.IMAIMessageStreamStartRequestBody
import com.xmtx.imclientkit.networking.HTTPQueryItem
import com.xmtx.imclientkit.networking.HTTPRequestSpec
import com.xmtx.imclientkit.networking.JsonConfiguration
import io.ktor.http.HttpMethod
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class IMAPI(
    private val json: Json = JsonConfiguration.default,
) {
    fun createConversation(
        kind: IMConversationKind,
        title: String?,
        memberEmails: List<String>,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations",
            method = HttpMethod.Post,
            body = json.encodeToString(
                IMConversationCreateRequestBody(
                    kind = kind.rawValue,
                    title = title,
                    memberEmails = memberEmails,
                ),
            ),
        )

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

    fun startAIMessageStream(conversationID: String, prompt: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/ai/messages",
            method = HttpMethod.Post,
            body = json.encodeToString(IMAIMessageStreamStartRequestBody(prompt)),
        )

    fun cancelMessageStream(conversationID: String, messageID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/messages/$messageID/stream/cancel",
            method = HttpMethod.Post,
        )

    fun messageStreamSnapshot(conversationID: String, messageID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/messages/$messageID/stream",
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

    fun members(
        conversationID: String,
        cursor: String? = null,
        limit: Int? = null,
        query: String? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/members",
            queryItems = listOfNotNull(
                cursor?.let { HTTPQueryItem("cursor", it) },
                limit?.let { HTTPQueryItem("limit", it.toString()) },
                query?.let { HTTPQueryItem("q", it) },
            ),
        )

    fun addMembers(conversationID: String, memberEmails: List<String>): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/members",
            method = HttpMethod.Post,
            body = json.encodeToString(IMConversationMemberUpdateRequestBody(memberEmails)),
        )

    fun removeMember(conversationID: String, memberUserID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/members/$memberUserID/remove",
            method = HttpMethod.Post,
        )

    fun updateMemberRole(
        conversationID: String,
        memberUserID: String,
        role: IMConversationMemberRole,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/members/$memberUserID/role",
            method = HttpMethod.Post,
            body = json.encodeToString(IMConversationMemberRoleUpdateRequestBody(role.rawValue)),
        )

    fun updateTitle(conversationID: String, title: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/title",
            method = HttpMethod.Post,
            body = json.encodeToString(IMConversationTitleUpdateRequestBody(title)),
        )

    fun updatePreferences(
        conversationID: String,
        isPinned: Boolean? = null,
        isMuted: Boolean? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/preferences",
            method = HttpMethod.Patch,
            body = json.encodeToString(IMConversationPreferencesUpdateRequestBody(isPinned, isMuted)),
        )

    fun updateMetadata(
        conversationID: String,
        title: String? = null,
        notice: String? = null,
        avatarPreset: String? = null,
        muteAll: Boolean? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/metadata",
            method = HttpMethod.Patch,
            body = json.encodeToString(
                IMConversationMetadataUpdateRequestBody(
                    title = title,
                    notice = notice,
                    avatarPreset = avatarPreset,
                    muteAll = muteAll,
                ),
            ),
        )

    fun updateMyMemberProfile(conversationID: String, memberNickname: String?): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/members/me",
            method = HttpMethod.Patch,
            body = json.encodeToString(IMConversationMemberSelfUpdateRequestBody(memberNickname)),
        )

    fun clearConversationForSelf(conversationID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/clear",
            method = HttpMethod.Post,
        )

    fun deleteConversationForSelf(conversationID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID",
            method = HttpMethod.Delete,
        )

    fun leaveConversation(conversationID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/im/conversations/$conversationID/leave",
            method = HttpMethod.Post,
        )
}
