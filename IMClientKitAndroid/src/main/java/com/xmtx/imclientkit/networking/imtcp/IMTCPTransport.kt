package com.xmtx.imclientkit.networking.imtcp

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.Socket

interface IMTCPTransport {
    suspend fun connect(host: String, port: Int): IMTCPTransportConnection
}

class IMTCPTransportConnection(
    val lines: Channel<String>,
    private val sendLineHandler: suspend (String) -> Unit,
    private val disconnectHandler: suspend () -> Unit,
) {
    suspend fun sendLine(line: String) {
        sendLineHandler(line)
    }

    suspend fun disconnect() {
        disconnectHandler()
    }
}

class SocketIMTCPTransport : IMTCPTransport {
    override suspend fun connect(host: String, port: Int): IMTCPTransportConnection =
        withContext(Dispatchers.IO) {
            val socket = Socket(host, port)
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val lines = Channel<String>(Channel.UNLIMITED)

            scope.launch {
                try {
                    while (!socket.isClosed) {
                        val line = reader.readLine() ?: break
                        lines.send(line)
                    }
                    lines.close()
                } catch (error: Throwable) {
                    lines.close(error)
                }
            }

            IMTCPTransportConnection(
                lines = lines,
                sendLineHandler = { line ->
                    withContext(Dispatchers.IO) {
                        writer.write(line)
                        writer.newLine()
                        writer.flush()
                    }
                },
                disconnectHandler = {
                    scope.cancel()
                    runCatching { socket.close() }
                    lines.close()
                },
            )
        }
}
