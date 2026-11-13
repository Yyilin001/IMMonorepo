package com.xmtx.im.swiftplatform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** Android-only mechanisms. Credentials and IM framing remain opaque Swift-owned bytes.
 * Load the embedding native library before install(). One host lives for the process.
 * Blocking calls are dispatched by Swift onto dedicated I/O queues, never the main thread.
 */
class AndroidRuntimePlatform internal constructor(
    context: Context,
    private val sockets: SSLSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory,
) {
    private val directory = File(context.applicationContext.noBackupFilesDir, "im-swift-secrets-v1")
    private val secretLock = Any()
    private val http = AndroidHttpCalls(context.applicationContext)
    val activeHttpCount: Int get() = http.activeCount
    private val connections = ConcurrentHashMap<Long, SSLSocket>()
    private val nextConnection = AtomicLong(1)
    private val connectionSlots = java.util.concurrent.Semaphore(64)
    val activeConnectionCount: Int get() = connections.size

    companion object {
        private const val LIMIT = 1_048_576
        private const val OK = 0
        private const val MISSING = 1
        private const val UNAVAILABLE = 2
        private const val MALFORMED = 3
        private const val INVALIDATED = 4
        private const val CLOSED = 5
        private const val INVALID = 6
        @Volatile private var installed: AndroidRuntimePlatform? = null

        @Synchronized fun install(context: Context): AndroidRuntimePlatform {
            return installed ?: AndroidRuntimePlatform(context).also {
                check(it.nativeInstall()) { "Android platform bridge already installed or unavailable" }
                installed = it
            }
        }
    }

    private external fun nativeInstall(): Boolean

    // JNI ABI: four-byte big-endian status followed by opaque payload. No exception text,
    // credential content or Java object pointers cross this boundary.
    @Suppress("unused")
    fun perform(operation: Int, handle: Long, name: String?, bytes: ByteArray?, value: Int): ByteArray {
        return try {
            val result: ByteArray? = when (operation) {
                20, 21, 22, 23, 24, 25, 26 -> http.perform(operation, handle, bytes)
                1, 2, 3 -> synchronized(secretLock) { secret(operation, requireNotNull(name), bytes) }
                10 -> {
                    check(connectionSlots.tryAcquire())
                    var socket: SSLSocket? = null
                    try {
                        socket = sockets.createSocket() as SSLSocket
                        socket.enabledProtocols = arrayOf("TLSv1.3")
                        val id = nextConnection.getAndIncrement()
                        connections[id] = socket
                        ByteBuffer.allocate(8).putLong(id).array()
                    } catch (error: Exception) {
                        runCatching { socket?.close() }; connectionSlots.release(); throw error
                    }
                }
                11 -> {
                    val socket = connections[handle] ?: return envelope(CLOSED)
                    require(value in 1..65535 && !name.isNullOrBlank())
                    socket.sslParameters = socket.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                    socket.connect(InetSocketAddress(name, value), 20_000)
                    socket.soTimeout = 20_000
                    socket.startHandshake()
                    socket.soTimeout = 0 // Runtime owns request deadlines; cancel closes blocking reads.
                    byteArrayOf()
                }
                12 -> {
                    require(bytes != null && bytes.size <= LIMIT)
                    val socket = connections[handle] ?: return envelope(CLOSED)
                    socket.outputStream.write(bytes)
                    byteArrayOf()
                }
                13 -> {
                    require(value in 1..LIMIT)
                    val socket = connections[handle] ?: return envelope(CLOSED)
                    val buffer = ByteArray(value)
                    val count = socket.inputStream.read(buffer)
                    if (count < 0) byteArrayOf() else buffer.copyOf(count)
                }
                14 -> {
                    connections.remove(handle)?.let { socket ->
                        try { socket.close() } finally { connectionSlots.release() }
                    }
                    byteArrayOf()
                }
                else -> return envelope(INVALID)
            }
            if (result == null) envelope(MISSING) else envelope(OK, result)
        } catch (_: AEADBadTagException) { envelope(MALFORMED)
        } catch (_: KeyPermanentlyInvalidatedException) { envelope(INVALIDATED)
        } catch (_: Invalidated) { envelope(INVALIDATED)
        } catch (_: Malformed) { envelope(MALFORMED)
        } catch (_: IllegalArgumentException) { envelope(INVALID)
        } catch (_: Exception) { envelope(UNAVAILABLE) }
    }

    private fun envelope(status: Int, bytes: ByteArray = byteArrayOf()) =
        ByteBuffer.allocate(4 + bytes.size).putInt(status).put(bytes).array()

    private class Invalidated : Exception()
    private class Malformed : Exception()

    private fun secret(operation: Int, name: String, bytes: ByteArray?): ByteArray? {
        require(name.matches(Regex("[A-Za-z0-9._-]{1,120}")))
        check(directory.isDirectory || directory.mkdirs())
        // A fixed suffix keeps user names distinct from AtomicFile .bak/.new artifacts.
        val file = AtomicFile(File(directory, "$name.sealed"))
        val alias = "com.xmtx.im.swift.$name.v1"
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        fun existingKey(): SecretKey = (keys.getKey(alias, null) as? SecretKey) ?: throw Invalidated()
        when (operation) {
            1 -> {
                // openRead restores an interrupted AtomicFile write before testing absence.
                val input = try { file.openRead() } catch (error: java.io.FileNotFoundException) {
                    if (file.baseFile.exists()) throw error else return null
                }
                val encrypted = input.use {
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (output.size() <= LIMIT + 29) {
                        val count = it.read(buffer, 0, minOf(buffer.size, LIMIT + 30 - output.size()))
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                if (encrypted.size !in 29..(LIMIT + 29) || encrypted[0] != 1.toByte()) throw Malformed()
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, existingKey(), GCMParameterSpec(128, encrypted, 1, 12))
                cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                return cipher.doFinal(encrypted, 13, encrypted.size - 13)
            }
            2 -> {
                require(bytes != null && bytes.size <= LIMIT)
                // Never silently replace a missing key underneath existing ciphertext.
                val key = if (keys.containsAlias(alias)) existingKey() else {
                    if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) throw Invalidated()
                    KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                        init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256).setRandomizedEncryptionRequired(true).build())
                    }.generateKey()
                }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key)
                cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                val encrypted = byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes)
                val output = file.startWrite()
                try { output.write(encrypted); file.finishWrite(output) }
                catch (error: Exception) { file.failWrite(output); throw error }
                return byteArrayOf()
            }
            else -> {
                file.delete()
                check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists() &&
                    !File(file.baseFile.path + ".new").exists())
                keys.deleteEntry(alias)
                return byteArrayOf()
            }
        }
    }
}
