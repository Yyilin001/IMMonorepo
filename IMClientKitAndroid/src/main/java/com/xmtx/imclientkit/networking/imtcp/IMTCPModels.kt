package com.xmtx.imclientkit.networking.imtcp

import com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.features.im.IMDirectPeerResponseBody
import com.xmtx.imclientkit.features.im.IMMediaAsset
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMReplyReference
import com.xmtx.imclientkit.features.im.IMRichTextContent
import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPChatDomainEventBody
import com.xmtx.imclientkit.features.im.IMTCPChatDomainEventPayload
import com.xmtx.imclientkit.features.im.IMTCPKickPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.features.im.IMTCPMessageStreamPayload
import com.xmtx.imclientkit.features.im.IMTextEntity
import com.xmtx.imclientkit.features.im.IMTextRange
import com.xmtx.imclientkit.generated.im.realtime.v1.Ack
import com.xmtx.imclientkit.generated.im.realtime.v1.AuthAccepted
import com.xmtx.imclientkit.generated.im.realtime.v1.AuthError
import com.xmtx.imclientkit.generated.im.realtime.v1.AuthRequest
import com.xmtx.imclientkit.generated.im.realtime.v1.ChatDomainEvent
import com.xmtx.imclientkit.generated.im.realtime.v1.ConversationMessage
import com.xmtx.imclientkit.generated.im.realtime.v1.ConversationSummary
import com.xmtx.imclientkit.generated.im.realtime.v1.Heartbeat
import com.xmtx.imclientkit.generated.im.realtime.v1.InlineCodeEntity
import com.xmtx.imclientkit.generated.im.realtime.v1.Kick
import com.xmtx.imclientkit.generated.im.realtime.v1.LinkEntity
import com.xmtx.imclientkit.generated.im.realtime.v1.MediaAsset
import com.xmtx.imclientkit.generated.im.realtime.v1.MessageContent
import com.xmtx.imclientkit.generated.im.realtime.v1.MessageDerivedState
import com.xmtx.imclientkit.generated.im.realtime.v1.MentionEntity
import com.xmtx.imclientkit.generated.im.realtime.v1.HashtagEntity
import com.xmtx.imclientkit.generated.im.realtime.v1.Packet
import com.xmtx.imclientkit.generated.im.realtime.v1.ReplyContent
import com.xmtx.imclientkit.generated.im.realtime.v1.ReplyReference
import com.xmtx.imclientkit.generated.im.realtime.v1.RichTextContent
import com.xmtx.imclientkit.generated.im.realtime.v1.SendMessageCommand
import com.xmtx.imclientkit.generated.im.realtime.v1.TextEntity
import com.xmtx.imclientkit.generated.im.realtime.v1.TextRange
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.time.Instant
import java.util.UUID

data class IMTCPClientConfiguration(
    val host: String,
    val port: Int,
    val protocolVersion: Int = 4,
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = "android",
    val appVersion: String? = null,
)

data class IMTCPAuthRequestPayload(
    val accessToken: String,
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = null,
    val appVersion: String? = null,
    val protocolVersion: Int,
)

data class IMTCPAuthAcceptedPayload(
    val connectionID: String,
    val userID: String,
    val sessionID: String,
    val heartbeatIntervalSeconds: Int,
    val serverTime: String,
)

data class IMTCPAuthErrorPayload(
    val code: String,
    val message: String,
)

data class IMTCPHeartbeatPayload(
    val sequence: Int,
)

sealed interface IMTCPConnectionEvent {
    data class HeartbeatAck(val requestID: String?, val payload: IMTCPHeartbeatPayload) : IMTCPConnectionEvent
    data class Ack(val requestID: String?, val payload: IMTCPAckPayload) : IMTCPConnectionEvent
    data class DomainEvent(val requestID: String?, val payload: IMTCPChatDomainEventPayload) : IMTCPConnectionEvent
    data class Kick(val payload: IMTCPKickPayload) : IMTCPConnectionEvent
}

sealed class IMTCPClientError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    object InvalidPacket : IMTCPClientError("Invalid TCP packet.")
    data class InvalidPayload(val packetType: String) : IMTCPClientError("Invalid payload for $packetType.")
    data class UnexpectedPacket(val packetType: String) : IMTCPClientError("Unexpected TCP packet $packetType.")
    data class AuthRejected(val code: String, val serverMessage: String) : IMTCPClientError(serverMessage)
    data class Kicked(val reason: String, val serverMessage: String) : IMTCPClientError(serverMessage)
    object ConnectionClosed : IMTCPClientError("TCP connection closed.")
}

internal object IMTCPPacketCodec {
    private const val protocolVersion: Int = 4

    fun encodeAuth(payload: IMTCPAuthRequestPayload): ByteArray =
        packetBuilder(null)
            .setAuth(
                AuthRequest.newBuilder()
                    .setAccessToken(payload.accessToken)
                    .also { if (payload.deviceID != null) it.deviceId = payload.deviceID }
                    .also { if (payload.deviceName != null) it.deviceName = payload.deviceName }
                    .also { if (payload.platform != null) it.platform = payload.platform }
                    .also { if (payload.appVersion != null) it.appVersion = payload.appVersion }
                    .build(),
            )
            .build()
            .toByteArray()

    fun encodeHeartbeat(payload: IMTCPHeartbeatPayload, requestID: String): ByteArray =
        packetBuilder(requestID)
            .setHeartbeat(Heartbeat.newBuilder().setSequence(payload.sequence).build())
            .build()
            .toByteArray()

    fun encodeSendMessage(payload: IMTCPMessagePayload, requestID: String): ByteArray =
        packetBuilder(requestID)
            .setSendMessage(
                SendMessageCommand.newBuilder()
                    .also { if (payload.clientMessageID != null) it.clientMessageId = payload.clientMessageID }
                    .setConversationId(payload.conversationID)
                    .setContent(payload.content.protobuf)
                    .build(),
            )
            .build()
            .toByteArray()

    fun encodeAck(payload: IMTCPAckPayload, requestID: String?): ByteArray =
        packetBuilder(requestID)
            .setAck(
                Ack.newBuilder()
                    .setMessageId(payload.messageID)
                    .also { if (payload.conversationID != null) it.conversationId = payload.conversationID }
                    .setStatus(payload.status)
                    .build(),
            )
            .build()
            .toByteArray()

    fun decode(frame: ByteArray): Packet =
        try {
            Packet.parseFrom(frame)
        } catch (error: Exception) {
            throw IMTCPClientError.InvalidPacket
        }

    fun authAccepted(packet: Packet): IMTCPAuthAcceptedPayload =
        when (packet.bodyCase) {
            Packet.BodyCase.AUTH_OK -> packet.authOk.domainValue
            Packet.BodyCase.AUTH_ERROR -> throw IMTCPClientError.AuthRejected(packet.authError.code, packet.authError.message)
            Packet.BodyCase.KICK -> throw IMTCPClientError.Kicked(packet.kick.reason, packet.kick.message)
            else -> throw IMTCPClientError.UnexpectedPacket(packet.bodyCase.name.lowercase())
        }

    fun event(packet: Packet): IMTCPConnectionEvent =
        when (packet.bodyCase) {
            Packet.BodyCase.HEARTBEAT_ACK -> IMTCPConnectionEvent.HeartbeatAck(packet.requestIDOrNull, packet.heartbeatAck.domainValue)
            Packet.BodyCase.ACK -> IMTCPConnectionEvent.Ack(packet.requestIDOrNull, packet.ack.domainValue)
            Packet.BodyCase.DOMAIN_EVENT -> IMTCPConnectionEvent.DomainEvent(packet.requestIDOrNull, packet.domainEvent.domainValue)
            Packet.BodyCase.KICK -> IMTCPConnectionEvent.Kick(packet.kick.domainValue)
            else -> throw IMTCPClientError.UnexpectedPacket(packet.bodyCase.name.lowercase())
        }

    private fun packetBuilder(requestID: String?): Packet.Builder =
        Packet.newBuilder()
            .also { if (requestID != null) it.requestId = requestID }
            .setTimestampMs(System.currentTimeMillis())
            .setProtocolVersion(protocolVersion)
}

private val Packet.requestIDOrNull: String?
    get() = if (hasRequestId()) requestId else null

private val AuthAccepted.domainValue: IMTCPAuthAcceptedPayload
    get() = IMTCPAuthAcceptedPayload(
        connectionID = connectionId,
        userID = userId,
        sessionID = sessionId,
        heartbeatIntervalSeconds = heartbeatIntervalSeconds,
        serverTime = serverTimeMs.isoMillis,
    )

private val Heartbeat.domainValue: IMTCPHeartbeatPayload
    get() = IMTCPHeartbeatPayload(sequence)

private val Ack.domainValue: IMTCPAckPayload
    get() = IMTCPAckPayload(
        messageID = messageId,
        conversationID = if (hasConversationId()) conversationId else null,
        status = status,
    )

private val Kick.domainValue: IMTCPKickPayload
    get() = IMTCPKickPayload(reason = reason, message = message)

private val ChatDomainEvent.domainValue: IMTCPChatDomainEventPayload
    get() = IMTCPChatDomainEventPayload(
        eventID = eventId,
        eventType = eventType,
        aggregateType = aggregateType,
        aggregateID = aggregateId,
        aggregateSequence = aggregateSequence.toULong(),
        occurredAt = occurredAtMs.isoMillis,
        actorUserID = if (hasActorUserId()) actorUserId else null,
        conversation = if (hasConversation()) conversation.domainValue else null,
        body = domainBody,
    )

private val ChatDomainEvent.domainBody: IMTCPChatDomainEventBody
    get() = when (bodyCase) {
        ChatDomainEvent.BodyCase.MESSAGE_CREATED -> IMTCPChatDomainEventBody.MessageCreated(
            message = messageCreated.message.domainValue,
            clientMessageID = if (messageCreated.hasClientMessageId()) messageCreated.clientMessageId else null,
        )
        ChatDomainEvent.BodyCase.MESSAGE_EDITED -> IMTCPChatDomainEventBody.MessageUpdated(
            messageID = messageEdited.messageId,
            message = if (messageEdited.hasMessage()) messageEdited.message.domainValue else null,
        )
        ChatDomainEvent.BodyCase.MESSAGE_REVOKED -> IMTCPChatDomainEventBody.MessageRevoked(
            messageID = messageRevoked.messageId,
            revokedAt = messageRevoked.revokedAtMs.isoMillis,
            revokedByUserID = if (messageRevoked.hasRevokedByUserId()) messageRevoked.revokedByUserId else null,
            message = if (messageRevoked.hasMessage()) messageRevoked.message.domainValue else null,
        )
        ChatDomainEvent.BodyCase.MESSAGE_VISIBILITY_CHANGED -> IMTCPChatDomainEventBody.MessageVisibilityChanged(
            messageIDs = messageVisibilityChanged.messageIdsList,
            message = if (messageVisibilityChanged.hasMessage()) messageVisibilityChanged.message.domainValue else null,
            visibilityAction = if (messageVisibilityChanged.hasVisibilityAction()) messageVisibilityChanged.visibilityAction else null,
        )
        ChatDomainEvent.BodyCase.MESSAGE_FAVORITE_CHANGED -> IMTCPChatDomainEventBody.MessageFavoriteChanged(
            messageID = messageFavoriteChanged.messageId,
            isFavorited = messageFavoriteChanged.isFavorited,
        )
        ChatDomainEvent.BodyCase.MESSAGE_STREAM_STARTED,
        ChatDomainEvent.BodyCase.MESSAGE_STREAM_COMPLETED,
        ChatDomainEvent.BodyCase.MESSAGE_STREAM_FAILED,
        ChatDomainEvent.BodyCase.MESSAGE_STREAM_CANCELLED -> {
            val event = when (bodyCase) {
                ChatDomainEvent.BodyCase.MESSAGE_STREAM_STARTED -> messageStreamStarted
                ChatDomainEvent.BodyCase.MESSAGE_STREAM_COMPLETED -> messageStreamCompleted
                ChatDomainEvent.BodyCase.MESSAGE_STREAM_FAILED -> messageStreamFailed
                else -> messageStreamCancelled
            }
            IMTCPChatDomainEventBody.MessageStream(
                stream = event.stream.domainValue,
                message = if (event.hasMessage()) event.message.domainValue else null,
            )
        }
        ChatDomainEvent.BodyCase.CONVERSATION_REMOVED_FOR_SELF -> IMTCPChatDomainEventBody.ConversationChanged(removedForSelf = true)
        ChatDomainEvent.BodyCase.CONVERSATION_VISIBILITY_CHANGED -> IMTCPChatDomainEventBody.ConversationVisibilityChanged(
            visibilityAction = conversationVisibilityChanged.visibilityAction,
            messageIDs = conversationVisibilityChanged.messageIdsList,
        )
        ChatDomainEvent.BodyCase.MEMBER_ADDED -> IMTCPChatDomainEventBody.MemberChanged(memberAdded.memberUserIdsList)
        ChatDomainEvent.BodyCase.MEMBER_REMOVED -> IMTCPChatDomainEventBody.MemberChanged(memberRemoved.memberUserIdsList)
        ChatDomainEvent.BodyCase.MEMBER_ROLE_UPDATED -> IMTCPChatDomainEventBody.MemberChanged(memberRoleUpdated.memberUserIdsList)
        ChatDomainEvent.BodyCase.CONTACT_REQUEST_CREATED -> IMTCPChatDomainEventBody.ContactChanged(contactUserID = if (contactRequestCreated.hasContactUserId()) contactRequestCreated.contactUserId else null)
        ChatDomainEvent.BodyCase.CONTACT_REQUEST_ACCEPTED -> IMTCPChatDomainEventBody.ContactChanged(contactUserID = if (contactRequestAccepted.hasContactUserId()) contactRequestAccepted.contactUserId else null)
        ChatDomainEvent.BodyCase.CONTACT_REQUEST_UPDATED -> IMTCPChatDomainEventBody.ContactChanged(contactUserID = if (contactRequestUpdated.hasContactUserId()) contactRequestUpdated.contactUserId else null)
        ChatDomainEvent.BodyCase.CONVERSATION_CREATED,
        ChatDomainEvent.BodyCase.CONVERSATION_UPDATED,
        ChatDomainEvent.BodyCase.CONVERSATION_ACTIVITY_HINT,
        ChatDomainEvent.BodyCase.CONVERSATION_SETTINGS_CHANGED -> IMTCPChatDomainEventBody.ConversationChanged()
        ChatDomainEvent.BodyCase.BODY_NOT_SET -> throw IMTCPClientError.InvalidPayload("domain_event")
    }

private val ConversationSummary.domainValue: IMConversationSummaryResponseBody
    get() = IMConversationSummaryResponseBody(
        id = id,
        title = if (hasTitle()) title else null,
        kind = kind,
        directMessagingState = if (hasDirectMessagingState()) directMessagingState else null,
        directPeer = if (hasDirectPeer()) {
            IMDirectPeerResponseBody(
                id = directPeer.id,
                email = directPeer.email,
                displayName = if (directPeer.hasDisplayName()) directPeer.displayName else null,
                avatarPreset = if (directPeer.hasAvatarPreset()) directPeer.avatarPreset else null,
            )
        } else {
            null
        },
        memberCount = memberCount,
        memberUserIDs = memberUserIdsList,
        notice = if (hasNotice()) notice else null,
        avatarPreset = if (hasAvatarPreset()) avatarPreset else null,
        muteAll = muteAll,
        lastMessage = if (hasLastMessage()) {
            com.xmtx.imclientkit.features.im.IMMessagePreviewResponseBody(
                id = lastMessage.id,
                senderUserID = lastMessage.senderUserId,
                serverSequence = lastMessage.serverSequence.toIntSequence("last_message.server_sequence"),
                content = lastMessage.content.domainValue,
                derivedState = lastMessage.derivedState.jsonValue,
                createdAt = if (lastMessage.hasCreatedAtMs()) lastMessage.createdAtMs.isoMillis else null,
            )
        } else {
            null
        },
        lastReadSequence = lastReadSequence.toIntSequence("last_read_sequence"),
        unreadCount = unreadCount,
        isPinned = isPinned,
        pinnedAt = if (hasPinnedAtMs()) pinnedAtMs.isoMillis else null,
        isMuted = isMuted,
        createdAt = if (hasCreatedAtMs()) createdAtMs.isoMillis else null,
        updatedAt = updatedAtMs.isoMillis,
    )

private val ConversationMessage.domainValue: IMConversationMessageResponseBody
    get() = IMConversationMessageResponseBody(
        id = id,
        conversationID = conversationId,
        senderUserID = senderUserId,
        clientMessageID = if (hasClientMessageId()) clientMessageId else null,
        serverSequence = serverSequence.toIntSequence("message.server_sequence"),
        content = content.domainValue,
        derivedState = derivedState.jsonValue,
        createdAt = if (hasCreatedAtMs()) createdAtMs.isoMillis else null,
    )

private val MessageContent.domainValue: IMMessageContent
    get() = when (bodyCase) {
        MessageContent.BodyCase.RICH_TEXT -> IMMessageContent.RichText(richText.domainValue)
        MessageContent.BodyCase.REPLY -> IMMessageContent.Reply(reply.reference.domainValue, reply.body.domainValue)
        MessageContent.BodyCase.IMAGE -> IMMessageContent.Media("image", image.domainValue)
        MessageContent.BodyCase.AUDIO -> IMMessageContent.Media("audio", audio.domainValue)
        MessageContent.BodyCase.FILE -> IMMessageContent.Media("file", file.domainValue)
        MessageContent.BodyCase.BODY_NOT_SET -> throw IMTCPClientError.InvalidPayload("message_content")
    }

private val IMMessageContent.protobuf: MessageContent
    get() {
        val builder = MessageContent.newBuilder()
        when (this) {
            is IMMessageContent.RichText -> builder.richText = body.protobuf
            is IMMessageContent.Reply -> builder.reply = ReplyContent.newBuilder()
                .setReference(reference.protobuf)
                .setBody(body.protobuf)
                .build()
            is IMMessageContent.Media -> {
                when (type) {
                    "image" -> builder.image = asset.protobuf
                    "audio" -> builder.audio = asset.protobuf
                    else -> builder.file = asset.protobuf
                }
            }
            is IMMessageContent.Unsupported -> throw IMTCPClientError.InvalidPayload("message_content")
        }
        return builder.build()
    }

private val RichTextContent.domainValue: IMRichTextContent
    get() = IMRichTextContent(text = text, entities = entitiesList.map { it.domainValue })

private val IMRichTextContent.protobuf: RichTextContent
    get() = RichTextContent.newBuilder()
        .setText(text)
        .addAllEntities(entities.map { it.protobuf })
        .build()

private val TextEntity.domainValue: IMTextEntity
    get() = when (bodyCase) {
        TextEntity.BodyCase.LINK -> IMTextEntity.Link(range.domainValue, link.url)
        TextEntity.BodyCase.MENTION -> IMTextEntity.Mention(range.domainValue, mention.userId)
        TextEntity.BodyCase.HASHTAG -> IMTextEntity.Hashtag(range.domainValue, hashtag.value)
        TextEntity.BodyCase.INLINE_CODE -> IMTextEntity.InlineCode(range.domainValue)
        TextEntity.BodyCase.BODY_NOT_SET -> throw IMTCPClientError.InvalidPayload("text_entity")
    }

private val IMTextEntity.protobuf: TextEntity
    get() {
        val builder = TextEntity.newBuilder().setRange(range.protobuf)
        when (this) {
            is IMTextEntity.Link -> builder.link = LinkEntity.newBuilder().setUrl(url).build()
            is IMTextEntity.Mention -> builder.mention = MentionEntity.newBuilder().setUserId(userID).build()
            is IMTextEntity.Hashtag -> builder.hashtag = HashtagEntity.newBuilder().setValue(value).build()
            is IMTextEntity.InlineCode -> builder.inlineCode = InlineCodeEntity.newBuilder().build()
        }
        return builder.build()
    }

private val TextRange.domainValue: IMTextRange
    get() = IMTextRange(location = location, length = length)

private val IMTextRange.protobuf: TextRange
    get() = TextRange.newBuilder().setLocation(location).setLength(length).build()

private val ReplyReference.domainValue: IMReplyReference
    get() = IMReplyReference(
        messageID = messageId,
        senderUserID = if (hasSenderUserId()) senderUserId else null,
        previewText = previewText,
    )

private val IMReplyReference.protobuf: ReplyReference
    get() = ReplyReference.newBuilder()
        .setMessageId(messageID)
        .also { if (senderUserID != null) it.senderUserId = senderUserID }
        .setPreviewText(previewText)
        .build()

private val MediaAsset.domainValue: IMMediaAsset
    get() = IMMediaAsset(
        assetID = assetId,
        kind = kind,
        mimeType = mimeType,
        byteSize = byteSize,
        filename = filename,
        width = if (hasWidth()) width else null,
        height = if (hasHeight()) height else null,
        durationMillis = if (hasDurationMillis()) durationMillis else null,
        previewAssetID = if (hasPreviewAssetId()) previewAssetId else null,
    )

private val IMMediaAsset.protobuf: MediaAsset
    get() = MediaAsset.newBuilder()
        .setAssetId(assetID)
        .setKind(kind)
        .setMimeType(mimeType)
        .setByteSize(byteSize)
        .setFilename(filename)
        .also { if (width != null) it.width = width }
        .also { if (height != null) it.height = height }
        .also { if (durationMillis != null) it.durationMillis = durationMillis }
        .also { if (previewAssetID != null) it.previewAssetId = previewAssetID }
        .build()

private val MessageDerivedState.jsonValue: JsonObject
    get() = buildJsonObject {
        put("recallState", JsonPrimitive(recallState.ifEmpty { "active" }))
        if (hasStreamState()) {
            put(
                "streamState",
                buildJsonObject {
                    put("streamID", JsonPrimitive(streamState.streamId))
                    put("state", JsonPrimitive(streamState.state))
                    put("lastChunkIndex", JsonPrimitive(streamState.lastChunkIndex))
                    put("partialText", JsonPrimitive(streamState.partialText))
                    if (streamState.hasErrorCode()) put("errorCode", JsonPrimitive(streamState.errorCode))
                    if (streamState.hasErrorMessage()) put("errorMessage", JsonPrimitive(streamState.errorMessage))
                    put("updatedAt", JsonPrimitive(streamState.updatedAtMs.isoMillis))
                    put("isAIGenerated", JsonPrimitive(streamState.isAiGenerated))
                },
            )
        }
    }

private val com.xmtx.imclientkit.generated.im.realtime.v1.MessageStreamPayload.domainValue: IMTCPMessageStreamPayload
    get() = IMTCPMessageStreamPayload(
        streamID = streamId,
        messageID = messageId,
        conversationID = conversationId,
        chunkIndex = chunkIndex,
        deltaText = if (hasDeltaText()) deltaText else null,
        partialTextLength = partialTextLength,
        state = state,
        serverTimestamp = serverTimestampMs.isoMillis,
    )

private val Long.isoMillis: String
    get() = Instant.ofEpochMilli(this).toString()

private fun Long.toIntSequence(fieldName: String): Int {
    if (this < Int.MIN_VALUE || this > Int.MAX_VALUE) {
        throw IMTCPClientError.InvalidPayload(fieldName)
    }
    return toInt()
}
