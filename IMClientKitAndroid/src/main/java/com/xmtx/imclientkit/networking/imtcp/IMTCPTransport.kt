package com.xmtx.imclientkit.networking.imtcp

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket

interface IMTCPTransport {
    suspend fun connect(host: String, port: Int): IMTCPTransportConnection
}

class IMTCPTransportConnection(
    val frames: Channel<ByteArray>,
    private val sendFrameHandler: suspend (ByteArray) -> Unit,
    private val disconnectHandler: suspend () -> Unit,
) {
    suspend fun sendFrame(frame: ByteArray) {
        sendFrameHandler(frame)
    }

    suspend fun disconnect() {
        disconnectHandler()
    }
}

class SocketIMTCPTransport : IMTCPTransport {
    override suspend fun connect(host: String, port: Int): IMTCPTransportConnection =
        withContext(Dispatchers.IO) {
            val socket = Socket(host, port)
            val reader = DataInputStream(socket.getInputStream())
            val writer = DataOutputStream(socket.getOutputStream())
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val frames = Channel<ByteArray>(Channel.UNLIMITED)

            scope.launch {
                try {
                    while (!socket.isClosed) {
                        val length = reader.readInt()
                        if (length <= 0 || length > 64 * 1024) {
                            throw IMTCPClientError.InvalidPacket
                        }
                        val frame = ByteArray(length)
                        reader.readFully(frame)
                        frames.send(frame)
                    }
                    frames.close()
                } catch (error: Throwable) {
                    frames.close(error)
                }
            }

            IMTCPTransportConnection(
                frames = frames,
                sendFrameHandler = { frame ->
                    withContext(Dispatchers.IO) {
                        if (frame.size > 64 * 1024) {
                            throw IMTCPClientError.InvalidPacket
                        }
                        writer.writeInt(frame.size)
                        writer.write(frame)
                        writer.flush()
                    }
                },
                disconnectHandler = {
                    scope.cancel()
                    runCatching { socket.close() }
                    frames.close()
                },
            )
        }
}
