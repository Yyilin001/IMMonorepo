package com.xmtx.imclientkit.networking.imtcp

import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.flow.map
import java.util.UUID

class IMTCPConnection(
    val authentication: IMTCPAuthAcceptedPayload,
    val events: Flow<IMTCPConnectionEvent>,
    private val transportConnection: IMTCPTransportConnection,
) {
    suspend fun sendHeartbeat(sequence: Int, requestID: String = UUID.randomUUID().toString()) {
        transportConnection.sendFrame(IMTCPPacketCodec.encodeHeartbeat(IMTCPHeartbeatPayload(sequence), requestID))
    }

    suspend fun sendMessage(payload: IMTCPMessagePayload, requestID: String = UUID.randomUUID().toString()) {
        transportConnection.sendFrame(IMTCPPacketCodec.encodeSendMessage(payload, requestID))
    }

    suspend fun sendAcknowledgement(payload: IMTCPAckPayload, requestID: String? = UUID.randomUUID().toString()) {
        transportConnection.sendFrame(IMTCPPacketCodec.encodeAck(payload, requestID))
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
        transportConnection.sendFrame(IMTCPPacketCodec.encodeAuth(authPayload))

        val authFrame = transportConnection.frames.receiveCatching().getOrNull() ?: run {
            transportConnection.disconnect()
            throw IMTCPClientError.ConnectionClosed
        }
        val authPacket = IMTCPPacketCodec.decode(authFrame)
        val authentication = try {
            IMTCPPacketCodec.authAccepted(authPacket)
        } catch (error: IMTCPClientError) {
            transportConnection.disconnect()
            throw error
        } catch (_: Throwable) {
            transportConnection.disconnect()
            throw IMTCPClientError.UnexpectedPacket(authPacket.bodyCase.name)
        }

        val events = transportConnection.frames.consumeAsFlow().map { frame ->
            val packet = IMTCPPacketCodec.decode(frame)
            IMTCPPacketCodec.event(packet)
        }

        return IMTCPConnection(authentication, events, transportConnection)
    }
}
