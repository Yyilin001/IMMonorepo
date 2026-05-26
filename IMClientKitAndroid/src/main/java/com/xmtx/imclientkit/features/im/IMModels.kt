package com.xmtx.imclientkit.features.im

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.util.UUID

enum class IMConversationKind(val rawValue: String) {
    Direct("direct"),
    Group("group");

    companion object {
        fun from(rawValue: String): IMConversationKind =
            entries.firstOrNull { it.rawValue == rawValue } ?: Group
    }
}

enum class IMConversationMemberRole(val rawValue: String) {
    Owner("owner"),
    Admin("admin"),
    Member("member");
}

@Serializable
data class IMConversationCreateRequestBody(
    val kind: String,
    val title: String? = null,
    val memberEmails: List<String>,
)

@Serializable
data class IMConversationMemberUpdateRequestBody(
    val memberEmails: List<String>,
)

@Serializable
data class IMConversationMemberRoleUpdateRequestBody(
    val role: String,
)

@Serializable
data class IMConversationTitleUpdateRequestBody(
    val title: String,
)

@Serializable
data class IMConversationPreferencesUpdateRequestBody(
    val isPinned: Boolean? = null,
    val isMuted: Boolean? = null,
)

@Serializable
data class IMConversationMetadataUpdateRequestBody(
    val title: String? = null,
    val notice: String? = null,
    val avatarPreset: String? = null,
    val muteAll: Boolean? = null,
)

@Serializable
data class IMConversationMemberSelfUpdateRequestBody(
    val memberNickname: String? = null,
)

@Serializable
data class IMConversationMemberResponseBody(
    val id: String,
    val email: String,
    val displayName: String? = null,
    val avatarPreset: String? = null,
    val role: String = IMConversationMemberRole.Member.rawValue,
    val memberNickname: String? = null,
    val joinedAt: String? = null,
) {
    val preferredDisplayName: String
        get() = memberNickname?.trim()?.takeIf { it.isNotEmpty() }
            ?: displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: email
}

@Serializable
data class IMConversationMemberPageResponseBody(
    val items: List<IMConversationMemberResponseBody>,
    val nextCursor: String? = null,
    val hasMore: Boolean,
)

@Serializable
data class IMDirectPeerResponseBody(
    val id: String,
    val email: String,
    val displayName: String? = null,
    val avatarPreset: String? = null,
)

@Serializable
data class IMMessagePreviewResponseBody(
    val id: String,
    val senderUserID: String,
    val serverSequence: Int,
    val content: IMMessageContent,
    val derivedState: JsonObject = buildJsonObject { },
    val createdAt: String? = null,
) {
    val previewText: String
        get() = content.previewText
}

@Serializable
data class IMConversationSummaryResponseBody(
    val id: String,
    val title: String? = null,
    val kind: String = IMConversationKind.Group.rawValue,
    val directMessagingState: String? = null,
    val directPeer: IMDirectPeerResponseBody? = null,
    val memberCount: Int,
    val memberUserIDs: List<String> = emptyList(),
    val notice: String? = null,
    val avatarPreset: String? = null,
    val muteAll: Boolean = false,
    val lastMessage: IMMessagePreviewResponseBody? = null,
    val lastReadSequence: Int = 0,
    val unreadCount: Int = 0,
    val isPinned: Boolean = false,
    val pinnedAt: String? = null,
    val isMuted: Boolean = false,
    val createdAt: String? = null,
    val updatedAt: String,
) {
    val displayTitle: String
        get() = title?.trim()?.takeIf { it.isNotEmpty() }
            ?: directPeer?.displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: directPeer?.email
            ?: "Conversation"
}

@Serializable
data class IMConversationSummaryPageResponseBody(
    val items: List<IMConversationSummaryResponseBody>,
    val nextCursor: String? = null,
    val hasMore: Boolean,
    val snapshotToken: String,
)

@Serializable
data class IMConversationSummaryChangesResponseBody(
    val upserts: List<IMConversationSummaryResponseBody>,
    val removedConversationIDs: List<String>,
    val nextCursor: String? = null,
    val hasMore: Boolean,
    val targetToken: String,
)

@Serializable
data class IMConversationMessageResponseBody(
    val id: String,
    val conversationID: String,
    val senderUserID: String,
    val clientMessageID: String? = null,
    val serverSequence: Int,
    val content: IMMessageContent,
    val derivedState: JsonObject = buildJsonObject { },
    val createdAt: String? = null,
) {
    val previewText: String
        get() = content.previewText
}

@Serializable
data class IMConversationMessagesSinceResponseBody(
    val messages: List<IMConversationMessageResponseBody>,
    val hasMore: Boolean,
    val nextAfterSequence: Int? = null,
)

@Serializable
data class IMConversationReadRequestBody(
    val readSequence: ULong,
)

@Serializable
data class IMConversationReadResponseBody(
    val conversationID: String,
    val lastReadSequence: Int,
    val unreadCount: Int,
)

enum class IMConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    Failed,
}

enum class IMMessageDirection {
    Incoming,
    Outgoing,
}

enum class IMMessageDeliveryState {
    Queued,
    Sending,
    Sent,
    Received,
    Unknown,
    Failed,
}

enum class IMMessageStreamLifecycleState(val rawValue: String) {
    Streaming("streaming"),
    Completed("completed"),
    Failed("failed"),
    Cancelled("cancelled");

    val isTerminal: Boolean
        get() = this != Streaming

    companion object {
        fun from(rawValue: String?): IMMessageStreamLifecycleState? =
            entries.firstOrNull { it.rawValue == rawValue }
    }
}

data class IMMessageStreamState(
    val streamID: String,
    val state: IMMessageStreamLifecycleState,
    val lastChunkIndex: Int = 0,
    val partialText: String = "",
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val updatedAt: String? = null,
    val isAIGenerated: Boolean = true,
)

data class IMActiveMessageStreamTarget(
    val conversationID: String,
    val messageID: String,
    val streamID: String,
)

fun JsonObject.messageStreamState(): IMMessageStreamState? {
    val raw = this["streamState"]?.jsonObject ?: return null
    val streamID = raw["streamID"]?.jsonPrimitive?.contentOrNull ?: return null
    val state = IMMessageStreamLifecycleState.from(raw["state"]?.jsonPrimitive?.contentOrNull) ?: return null
    return IMMessageStreamState(
        streamID = streamID,
        state = state,
        lastChunkIndex = raw["lastChunkIndex"]?.jsonPrimitive?.intOrNull ?: 0,
        partialText = raw["partialText"]?.jsonPrimitive?.contentOrNull.orEmpty(),
        errorCode = raw["errorCode"]?.jsonPrimitive?.contentOrNull,
        errorMessage = raw["errorMessage"]?.jsonPrimitive?.contentOrNull,
        updatedAt = raw["updatedAt"]?.jsonPrimitive?.contentOrNull,
        isAIGenerated = raw["isAIGenerated"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: true,
    )
}

fun JsonObject.withMessageStreamState(state: IMMessageStreamState): JsonObject =
    buildJsonObject {
        this@withMessageStreamState.forEach { (key, value) -> put(key, value) }
        put(
            "streamState",
            buildJsonObject {
                put("streamID", JsonPrimitive(state.streamID))
                put("state", JsonPrimitive(state.state.rawValue))
                put("lastChunkIndex", JsonPrimitive(state.lastChunkIndex))
                put("partialText", JsonPrimitive(state.partialText))
                state.errorCode?.let { put("errorCode", JsonPrimitive(it)) }
                state.errorMessage?.let { put("errorMessage", JsonPrimitive(it)) }
                state.updatedAt?.let { put("updatedAt", JsonPrimitive(it)) }
                put("isAIGenerated", JsonPrimitive(state.isAIGenerated))
            },
        )
    }

fun JsonObject.withRecallState(state: String): JsonObject =
    buildJsonObject {
        this@withRecallState.forEach { (key, value) -> put(key, value) }
        put("recallState", JsonPrimitive(state))
    }

data class IMConversationMessage(
    val id: String,
    val conversationID: String,
    val clientMessageID: String?,
    val serverMessageID: String?,
    val senderUserID: String?,
    val serverSequence: ULong?,
    val content: IMMessageContent,
    val derivedState: JsonObject = buildJsonObject { },
    val direction: IMMessageDirection,
    val createdAt: String,
    val deliveryState: IMMessageDeliveryState,
) {
    val previewText: String
        get() = content.previewText

    val streamState: IMMessageStreamState?
        get() = derivedState.messageStreamState()
}

data class IMConversation(
    val id: String,
    val summary: IMConversationSummaryResponseBody,
    val messages: List<IMConversationMessage> = emptyList(),
    val members: List<IMConversationMemberResponseBody> = emptyList(),
    val membersNextCursor: String? = null,
    val hasMoreMembers: Boolean = false,
    val serverLastReadSequence: ULong = summary.lastReadSequence.toULong(),
    val serverUnreadCount: Int = summary.unreadCount,
    val localUnreadDelta: Int = 0,
) {
    val displayTitle: String
        get() = summary.displayTitle

    val unreadCount: Int
        get() = maxOf(0, serverUnreadCount + localUnreadDelta)

    val lastMessagePreview: String
        get() = messages.maxByOrNull { it.serverSequence ?: ULong.MAX_VALUE }?.previewText
            ?: summary.lastMessage?.previewText
            ?: "${summary.memberCount} members"
}

data class IMOutgoingMessageRequest(
    val requestID: String,
    val localMessageID: String,
    val payload: IMTCPMessagePayload,
)

data class IMTCPMessagePayload(
    val clientMessageID: String? = null,
    val messageID: String? = null,
    val conversationID: String,
    val senderUserID: String? = null,
    val serverSequence: ULong? = null,
    val serverTimestamp: String? = null,
    val content: IMMessageContent,
    val derivedState: JsonObject = buildJsonObject { },
)

@Serializable
data class IMTCPMessagePayloadWire(
    val clientMessageID: String? = null,
    val messageID: String? = null,
    val conversationID: String,
    val senderUserID: String? = null,
    val serverSequence: ULong? = null,
    val serverTimestamp: String? = null,
    val content: IMMessageContent,
    val derivedState: JsonObject = buildJsonObject { },
) {
    fun toDomain(): IMTCPMessagePayload =
        IMTCPMessagePayload(
            clientMessageID = clientMessageID,
            messageID = messageID,
            conversationID = conversationID,
            senderUserID = senderUserID,
            serverSequence = serverSequence,
            serverTimestamp = serverTimestamp,
            content = content,
            derivedState = derivedState,
        )

    companion object {
        fun fromDomain(payload: IMTCPMessagePayload): IMTCPMessagePayloadWire =
            IMTCPMessagePayloadWire(
                clientMessageID = payload.clientMessageID,
                messageID = payload.messageID,
                conversationID = payload.conversationID,
                senderUserID = payload.senderUserID,
                serverSequence = payload.serverSequence,
                serverTimestamp = payload.serverTimestamp,
                content = payload.content,
                derivedState = payload.derivedState,
            )
    }
}

@Serializable
data class IMTCPAckPayload(
    val messageID: String,
    val conversationID: String? = null,
    val status: String,
)

@Serializable
data class IMTCPConversationEventPayload(
    val eventType: String,
    val conversation: IMConversationSummaryResponseBody,
    val message: IMConversationMessageResponseBody? = null,
    val stream: IMTCPMessageStreamPayload? = null,
    val actorUserID: String? = null,
    val serverTimestamp: String,
    val messageIDs: List<String> = emptyList(),
    val visibilityAction: String? = null,
)

data class IMTCPChatDomainEventPayload(
    val eventID: String,
    val eventType: String,
    val aggregateType: String,
    val aggregateID: String,
    val aggregateSequence: ULong,
    val occurredAt: String,
    val actorUserID: String? = null,
    val conversation: IMConversationSummaryResponseBody? = null,
    val body: IMTCPChatDomainEventBody,
)

sealed interface IMTCPChatDomainEventBody {
    data class MessageCreated(
        val message: IMConversationMessageResponseBody,
        val clientMessageID: String? = null,
    ) : IMTCPChatDomainEventBody

    data class MessageUpdated(
        val messageID: String,
        val message: IMConversationMessageResponseBody? = null,
    ) : IMTCPChatDomainEventBody

    data class MessageRevoked(
        val messageID: String,
        val revokedAt: String,
        val revokedByUserID: String? = null,
        val message: IMConversationMessageResponseBody? = null,
    ) : IMTCPChatDomainEventBody

    data class MessageVisibilityChanged(
        val messageIDs: List<String>,
        val message: IMConversationMessageResponseBody? = null,
        val visibilityAction: String? = null,
    ) : IMTCPChatDomainEventBody

    data class MessageFavoriteChanged(
        val messageID: String,
        val isFavorited: Boolean,
    ) : IMTCPChatDomainEventBody

    data class MessageStream(
        val stream: IMTCPMessageStreamPayload,
        val message: IMConversationMessageResponseBody? = null,
    ) : IMTCPChatDomainEventBody

    data class ConversationChanged(val removedForSelf: Boolean = false) : IMTCPChatDomainEventBody
    data class ConversationVisibilityChanged(val visibilityAction: String, val messageIDs: List<String>) : IMTCPChatDomainEventBody
    data class MemberChanged(val memberUserIDs: List<String>) : IMTCPChatDomainEventBody
    data class ContactChanged(val request: JsonObject? = null, val contact: JsonObject? = null, val contactUserID: String? = null) : IMTCPChatDomainEventBody
}

@Serializable
data class IMTCPMessageStreamPayload(
    val streamID: String,
    val messageID: String,
    val conversationID: String,
    val chunkIndex: Int,
    val deltaText: String? = null,
    val partialTextLength: Int,
    val state: String,
    val serverTimestamp: String,
)

@Serializable
data class IMAIMessageStreamStartRequestBody(
    val prompt: String,
)

@Serializable
data class IMMessageStreamResponseBody(
    val message: IMConversationMessageResponseBody,
    val stream: IMTCPMessageStreamPayload,
)

@Serializable
data class IMTCPContactEventPayload(
    val eventType: String,
    val request: JsonObject? = null,
    val contact: JsonObject? = null,
    val contactUserID: String? = null,
    val actorUserID: String? = null,
    val serverTimestamp: String,
)

@Serializable
data class IMTCPKickPayload(
    val reason: String,
    val message: String,
)

fun IMConversationMessageResponseBody.toConversationMessage(currentUserID: String): IMConversationMessage =
    IMConversationMessage(
        id = id,
        conversationID = conversationID,
        clientMessageID = clientMessageID,
        serverMessageID = id,
        senderUserID = senderUserID,
        serverSequence = serverSequence.toULong(),
        content = content,
        derivedState = derivedState,
        direction = if (senderUserID == currentUserID) IMMessageDirection.Outgoing else IMMessageDirection.Incoming,
        createdAt = createdAt ?: Instant.now().toString(),
        deliveryState = if (senderUserID == currentUserID) IMMessageDeliveryState.Sent else IMMessageDeliveryState.Received,
    )

fun IMTCPMessagePayload.toConversationMessage(currentUserID: String): IMConversationMessage {
    val localID = clientMessageID ?: messageID ?: UUID.randomUUID().toString()
    return IMConversationMessage(
        id = messageID ?: localID,
        conversationID = conversationID,
        clientMessageID = clientMessageID,
        serverMessageID = messageID,
        senderUserID = senderUserID,
        serverSequence = serverSequence,
        content = content,
        derivedState = derivedState,
        direction = if (senderUserID == currentUserID) IMMessageDirection.Outgoing else IMMessageDirection.Incoming,
        createdAt = serverTimestamp ?: Instant.now().toString(),
        deliveryState = if (senderUserID == currentUserID) IMMessageDeliveryState.Sent else IMMessageDeliveryState.Received,
    )
}

@Serializable(with = IMMessageContentSerializer::class)
sealed interface IMMessageContent {
    val previewText: String

    companion object {
        fun plain(text: String): IMMessageContent = RichText(IMRichTextContent(text = text))
    }

    @Serializable
    data class RichText(val body: IMRichTextContent) : IMMessageContent {
        override val previewText: String
            get() = body.text
    }

    @Serializable
    data class Reply(
        val reference: IMReplyReference,
        val body: IMRichTextContent,
    ) : IMMessageContent {
        override val previewText: String
            get() = body.text
    }

    @Serializable
    data class Media(
        val type: String,
        val asset: IMMediaAsset,
    ) : IMMessageContent {
        override val previewText: String
            get() = when (type) {
                "image" -> "[Image] ${asset.filename}"
                "audio" -> "[Audio] ${asset.filename}"
                else -> "[File] ${asset.filename}"
            }
    }

    data class Unsupported(
        val type: String?,
        val raw: JsonObject,
    ) : IMMessageContent {
        override val previewText: String
            get() = "Unsupported message"
    }
}

@Serializable
data class IMRichTextContent(
    val text: String,
    val entities: List<IMTextEntity> = emptyList(),
)

@Serializable
data class IMTextRange(
    val location: Int,
    val length: Int,
)

@Serializable(with = IMTextEntitySerializer::class)
sealed interface IMTextEntity {
    val range: IMTextRange

    @Serializable
    data class Link(override val range: IMTextRange, val url: String) : IMTextEntity

    @Serializable
    data class Mention(override val range: IMTextRange, val userID: String) : IMTextEntity

    @Serializable
    data class Hashtag(override val range: IMTextRange, val value: String) : IMTextEntity

    @Serializable
    data class InlineCode(override val range: IMTextRange) : IMTextEntity
}

@Serializable
data class IMReplyReference(
    val messageID: String,
    val senderUserID: String? = null,
    val previewText: String,
)

@Serializable
data class IMMediaAsset(
    val assetID: String,
    val kind: String,
    val mimeType: String,
    val byteSize: Long,
    val filename: String,
    val width: Int? = null,
    val height: Int? = null,
    val durationMillis: Int? = null,
    val previewAssetID: String? = null,
)

object IMMessageContentSerializer : KSerializer<IMMessageContent> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor

    override fun deserialize(decoder: Decoder): IMMessageContent {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw SerializationException("IMMessageContent requires JSON decoding.")
        val raw = jsonDecoder.decodeJsonElement().jsonObject
        return when (val type = raw["type"]?.jsonPrimitive?.contentOrNull) {
            "rich_text" -> IMMessageContent.RichText(
                jsonDecoder.json.decodeFromJsonElement(IMRichTextContent.serializer(), raw.required("body")),
            )
            "reply" -> IMMessageContent.Reply(
                reference = jsonDecoder.json.decodeFromJsonElement(IMReplyReference.serializer(), raw.required("reference")),
                body = jsonDecoder.json.decodeFromJsonElement(IMRichTextContent.serializer(), raw.required("body")),
            )
            "image", "audio", "file" -> IMMessageContent.Media(
                type = type,
                asset = jsonDecoder.json.decodeFromJsonElement(IMMediaAsset.serializer(), raw.required("asset")),
            )
            else -> IMMessageContent.Unsupported(type, raw)
        }
    }

    override fun serialize(encoder: Encoder, value: IMMessageContent) {
        val jsonEncoder = encoder as? kotlinx.serialization.json.JsonEncoder
            ?: throw SerializationException("IMMessageContent requires JSON encoding.")
        val element = when (value) {
            is IMMessageContent.RichText -> buildJsonObject {
                put("type", JsonPrimitive("rich_text"))
                put("body", jsonEncoder.json.encodeToJsonElement(IMRichTextContent.serializer(), value.body))
            }
            is IMMessageContent.Reply -> buildJsonObject {
                put("type", JsonPrimitive("reply"))
                put("reference", jsonEncoder.json.encodeToJsonElement(IMReplyReference.serializer(), value.reference))
                put("body", jsonEncoder.json.encodeToJsonElement(IMRichTextContent.serializer(), value.body))
            }
            is IMMessageContent.Media -> buildJsonObject {
                put("type", JsonPrimitive(value.type))
                put("asset", jsonEncoder.json.encodeToJsonElement(IMMediaAsset.serializer(), value.asset))
            }
            is IMMessageContent.Unsupported -> value.raw
        }
        jsonEncoder.encodeJsonElement(element)
    }

    private fun JsonObject.required(key: String): JsonElement =
        get(key) ?: throw SerializationException("Missing '$key' in IMMessageContent.")

    private fun JsonObject.requiredString(key: String): String =
        required(key).jsonPrimitive.content
}

object IMTextEntitySerializer : KSerializer<IMTextEntity> {
    override val descriptor: SerialDescriptor = JsonObject.serializer().descriptor

    override fun deserialize(decoder: Decoder): IMTextEntity {
        val jsonDecoder = decoder as? JsonDecoder
            ?: throw SerializationException("IMTextEntity requires JSON decoding.")
        val raw = jsonDecoder.decodeJsonElement().jsonObject
        val range = jsonDecoder.json.decodeFromJsonElement(IMTextRange.serializer(), raw.required("range"))
        return when (val kind = raw.requiredString("kind")) {
            "link" -> IMTextEntity.Link(range, raw.requiredString("url"))
            "mention" -> IMTextEntity.Mention(range, raw.requiredString("userID"))
            "hashtag" -> IMTextEntity.Hashtag(range, raw.requiredString("value"))
            "inline_code" -> IMTextEntity.InlineCode(range)
            else -> throw SerializationException("Unsupported IMTextEntity kind '$kind'.")
        }
    }

    override fun serialize(encoder: Encoder, value: IMTextEntity) {
        val jsonEncoder = encoder as? kotlinx.serialization.json.JsonEncoder
            ?: throw SerializationException("IMTextEntity requires JSON encoding.")
        val element = buildJsonObject {
            put("range", jsonEncoder.json.encodeToJsonElement(IMTextRange.serializer(), value.range))
            when (value) {
                is IMTextEntity.Link -> {
                    put("kind", JsonPrimitive("link"))
                    put("url", JsonPrimitive(value.url))
                }
                is IMTextEntity.Mention -> {
                    put("kind", JsonPrimitive("mention"))
                    put("userID", JsonPrimitive(value.userID))
                }
                is IMTextEntity.Hashtag -> {
                    put("kind", JsonPrimitive("hashtag"))
                    put("value", JsonPrimitive(value.value))
                }
                is IMTextEntity.InlineCode -> {
                    put("kind", JsonPrimitive("inline_code"))
                }
            }
        }
        jsonEncoder.encodeJsonElement(element)
    }

    private fun JsonObject.required(key: String): JsonElement =
        get(key) ?: throw SerializationException("Missing '$key' in IMTextEntity.")

    private fun JsonObject.requiredString(key: String): String =
        required(key).jsonPrimitive.content
}
