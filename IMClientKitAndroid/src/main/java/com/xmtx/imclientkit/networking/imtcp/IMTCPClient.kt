package com.xmtx.imclientkit.networking.imtcp

import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPKickPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayloadWire
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.util.UUID

class IMTCPConnection(
    val authentication: IMTCPAuthAcceptedPayload,
    val events: Flow<IMTCPConnectionEvent>,
    private val transportConnection: IMTCPTransportConnection,
) {
    suspend fun sendHeartbeat(sequence: Int, requestID: String = UUID.randomUUID().toString()) {
        transportConnection.sendLine(
            IMTCPPacketCodec.encode(
                type = "heartbeat",
                requestID = requestID,
                payload = IMTCPHeartbeatPayload(sequence),
            ),
        )
    }

    suspend fun sendMessage(payload: IMTCPMessagePayload, requestID: String = UUID.randomUUID().toString()) {
        transportConnection.sendLine(
            IMTCPPacketCodec.encode(
                type = "message",
                requestID = requestID,
                payload = IMTCPMessagePayloadWire.fromDomain(payload),
            ),
        )
    }

    suspend fun sendAcknowledgement(payload: IMTCPAckPayload, requestID: String? = UUID.randomUUID().toString()) {
        transportConnection.sendLine(
            IMTCPPacketCodec.encode(
                type = "ack",
                requestID = requestID,
                payload = payload,
            ),
        )
    }

    suspend fun disconnect() {
        transportConnection.disconnect()
    }
}

class IMTCPClient(
    private val configuration: IMTCPClientConfiguration,
    private val transport: IMTCPTransport = SocketIMTCPTransport(),
    private val accessTokenProvider: suspend () -> String,
) {
    suspend fun connect(): IMTCPConnection {
        val transportConnection = transport.connect(configuration.host, configuration.port)
        val accessToken = accessTokenProvider()
        val authPayload = IMTCPAuthRequestPayload(
            accessToken = accessToken,
            deviceID = configuration.deviceID,
            deviceName = configuration.deviceName,
            platform = configuration.platform,
            appVersion = configuration.appVersion,
            protocolVersion = configuration.protocolVersion,
        )
        transportConnection.sendLine(
            IMTCPPacketCodec.encode(
                type = "auth",
                requestID = null,
                payload = authPayload,
            ),
        )

        val authLine = transportConnection.lines.receiveCatching().getOrNull() ?: run {
            transportConnection.disconnect()
            throw IMTCPClientError.ConnectionClosed
        }
        val authPacket = IMTCPPacketCodec.decode(authLine)
        val authentication = when (authPacket.type) {
            "auth_ok" -> IMTCPPacketCodec.decodePayload<IMTCPAuthAcceptedPayload>(authPacket)
            "auth_error" -> {
                val payload = runCatching {
                    IMTCPPacketCodec.decodePayload<IMTCPAuthErrorPayload>(authPacket)
                }.getOrElse { IMTCPAuthErrorPayload("auth_error", "TCP authentication failed.") }
                transportConnection.disconnect()
                throw IMTCPClientError.AuthRejected(payload.code, payload.message)
            }
            "kick" -> {
                val payload = runCatching {
                    IMTCPPacketCodec.decodePayload<IMTCPKickPayload>(authPacket)
                }.getOrElse { IMTCPKickPayload("protocol_error", "Connection was closed by server.") }
                transportConnection.disconnect()
                throw IMTCPClientError.Kicked(payload.reason, payload.message)
            }
            else -> {
                transportConnection.disconnect()
                throw IMTCPClientError.UnexpectedPacket(authPacket.type)
            }
        }

        val eventLines = Channel<String>(Channel.UNLIMITED)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope.launch {
            for (line in transportConnection.lines) {
                eventLines.send(line)
            }
            eventLines.close()
        }

        val events = eventLines.consumeAsFlow().map { line ->
            val packet = IMTCPPacketCodec.decode(line)
            IMTCPPacketCodec.event(packet)
        }

        return IMTCPConnection(authentication, events, transportConnection)
    }
}
