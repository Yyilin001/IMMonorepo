package com.xmtx.imclientkit.networking.imtcp

import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPContactEventPayload
import com.xmtx.imclientkit.features.im.IMTCPConversationEventPayload
import com.xmtx.imclientkit.features.im.IMTCPKickPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayloadWire
import com.xmtx.imclientkit.networking.JsonConfiguration
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import java.time.Instant
import java.util.UUID

data class IMTCPClientConfiguration(
    val host: String,
    val port: Int,
    val protocolVersion: Int = 3,
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = "android",
    val appVersion: String? = null,
)

@Serializable
data class IMTCPAuthRequestPayload(
    val accessToken: String,
    val deviceID: String? = null,
    val deviceName: String? = null,
    val platform: String? = null,
    val appVersion: String? = null,
    val protocolVersion: Int,
)

@Serializable
data class IMTCPAuthAcceptedPayload(
    val connectionID: String,
    val userID: String,
    val sessionID: String,
    val heartbeatIntervalSeconds: Int,
    val serverTime: String,
)

@Serializable
data class IMTCPAuthErrorPayload(
    val code: String,
    val message: String,
)

@Serializable
data class IMTCPHeartbeatPayload(
    val sequence: Int,
)

@Serializable
internal data class IMTCPPacketEnvelope(
    val type: String,
    val requestID: String? = null,
    val timestamp: String = Instant.now().toString(),
    val payload: JsonElement,
)

sealed interface IMTCPConnectionEvent {
    data class HeartbeatAck(val requestID: String?, val payload: IMTCPHeartbeatPayload) : IMTCPConnectionEvent
    data class Ack(val requestID: String?, val payload: IMTCPAckPayload) : IMTCPConnectionEvent
    data class Message(val requestID: String?, val payload: IMTCPMessagePayload) : IMTCPConnectionEvent
    data class ConversationEvent(val requestID: String?, val payload: IMTCPConversationEventPayload) : IMTCPConnectionEvent
    data class ContactEvent(val requestID: String?, val payload: IMTCPContactEventPayload) : IMTCPConnectionEvent
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
    val json: Json = JsonConfiguration.default

    inline fun <reified Payload> encode(
        type: String,
        requestID: String? = UUID.randomUUID().toString(),
        payload: Payload,
    ): String =
        json.encodeToString(
            IMTCPPacketEnvelope(
                type = type,
                requestID = requestID,
                payload = json.encodeToJsonElement(payload),
            ),
        )

    fun decode(line: String): IMTCPPacketEnvelope =
        try {
            json.decodeFromString(IMTCPPacketEnvelope.serializer(), line)
        } catch (error: SerializationException) {
            throw IMTCPClientError.InvalidPacket
        } catch (error: IllegalArgumentException) {
            throw IMTCPClientError.InvalidPacket
        }

    inline fun <reified Payload> decodePayload(packet: IMTCPPacketEnvelope): Payload =
        try {
            json.decodeFromJsonElement(packet.payload)
        } catch (error: SerializationException) {
            throw IMTCPClientError.InvalidPayload(packet.type)
        } catch (error: IllegalArgumentException) {
            throw IMTCPClientError.InvalidPayload(packet.type)
        }

    fun event(packet: IMTCPPacketEnvelope): IMTCPConnectionEvent =
        when (packet.type) {
            "heartbeat_ack" -> IMTCPConnectionEvent.HeartbeatAck(
                requestID = packet.requestID,
                payload = decodePayload(packet),
            )
            "ack" -> IMTCPConnectionEvent.Ack(
                requestID = packet.requestID,
                payload = decodePayload(packet),
            )
            "message" -> IMTCPConnectionEvent.Message(
                requestID = packet.requestID,
                payload = decodePayload<IMTCPMessagePayloadWire>(packet).toDomain(),
            )
            "conversation_event" -> IMTCPConnectionEvent.ConversationEvent(
                requestID = packet.requestID,
                payload = decodePayload(packet),
            )
            "contact_event" -> IMTCPConnectionEvent.ContactEvent(
                requestID = packet.requestID,
                payload = decodePayload(packet),
            )
            "kick" -> IMTCPConnectionEvent.Kick(payload = decodePayload(packet))
            else -> throw IMTCPClientError.UnexpectedPacket(packet.type)
        }
}
