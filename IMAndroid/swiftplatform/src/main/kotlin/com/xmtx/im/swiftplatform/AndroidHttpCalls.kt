package com.xmtx.im.swiftplatform

import android.util.Base64
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Auth and resource byte transport: platform trust (including explicit app network-security config), no redirects,
 * retries, cookies, disk cache or logging. Swift still owns account contracts and credential handling. */
internal class AndroidHttpCalls(context: android.content.Context) {
    private val connectivity = context.getSystemService(android.net.ConnectivityManager::class.java)
    private data class Binding(val network: android.net.Network, val cellular: Boolean, val expensive: Boolean, val constrained: Boolean)
    private val bindings = ConcurrentHashMap<Long, Binding>()
    private fun requireNetwork(binding: Binding) {
        val caps = checkNotNull(connectivity.getNetworkCapabilities(binding.network))
        val unmetered = caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        if (!binding.cellular) check(!caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) &&
            (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)))
        if (!binding.expensive) check(unmetered)
        if (!binding.constrained && !unmetered) check(connectivity.restrictBackgroundStatus == android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED)
    }
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).callTimeout(15, TimeUnit.SECONDS).build()
    private val calls = ConcurrentHashMap<Long, Call>()
    private val responses = ConcurrentHashMap<Long, Response>()
    private val next = AtomicLong(1)
    private val slots = Semaphore(32)
    val activeCount get() = calls.size
    fun perform(operation: Int, handle: Long, bytes: ByteArray?): ByteArray {
        when (operation) {
            20 -> {
                require(bytes != null && bytes.size <= 1_048_576)
                check(slots.tryAcquire())
                try {
                    val input = JSONObject(bytes.toString(Charsets.UTF_8))
                    val url = input.getString("url")
                    val builder = Request.Builder().url(url)
                    require(builder.build().url.isHttps)
                    val headers = input.getJSONObject("headers")
                    for (key in headers.keys()) builder.header(key, headers.getString(key))
                    val body = Base64.decode(input.getString("body"), Base64.NO_WRAP)
                    require(body.size <= 524_288)
                    val method = input.getString("method")
                    require(method in setOf("POST", "GET", "PUT", "DELETE"))
                    builder.method(method, if (method == "GET") null else body.toRequestBody())
                    val id = next.getAndIncrement()
                    calls[id] = client.newCall(builder.build())
                    return ByteBuffer.allocate(8).putLong(id).array()
                } catch (error: Exception) { slots.release(); throw error }
            }
            21 -> {
                val call = checkNotNull(calls[handle])
                return call.execute().use { response ->
                    val headers = JSONObject()
                    for (name in response.headers.names()) headers.put(name, response.headers.values(name).joinToString(", "))
                    val metadata = JSONObject().put("status", response.code).put("headers", headers).toString().toByteArray()
                    require(metadata.size <= 65_536)
                    val output = ByteArrayOutputStream()
                    output.write(ByteBuffer.allocate(4).putInt(metadata.size).array()); output.write(metadata)
                    val body = response.body
                    require(body == null || body.contentLength() <= 2_097_152)
                    body?.byteStream()?.use { stream ->
                        val buffer = ByteArray(8192)
                        var count = 0
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            count += read
                            require(count <= 2_097_152)
                            output.write(buffer, 0, read)
                        }
                    }
                    output.toByteArray()
                }
            }
            22 -> calls[handle]?.cancel()
            23 -> calls.remove(handle)?.let { it.cancel(); responses.remove(handle)?.close(); bindings.remove(handle); slots.release() }
            24 -> {
                require(bytes != null && bytes.size <= 65_536)
                check(slots.tryAcquire())
                try {
                    val input = JSONObject(bytes.toString(Charsets.UTF_8))
                    val builder = Request.Builder().url(input.getString("url"))
                    require(builder.build().url.isHttps)
                    val headers = input.getJSONObject("headers")
                    for (key in headers.keys()) builder.header(key, headers.getString(key))
                    val method = input.getString("method"); require(method in setOf("PUT", "GET"))
                    val body = if (method == "PUT") {
                        val file = File(input.getString("path"))
                        require(file.isFile && file.canonicalPath == file.absolutePath && file.length() in 1..33_554_432)
                        file.asRequestBody()
                    } else null
                    builder.method(method, body)
                    val binding = Binding(checkNotNull(connectivity.activeNetwork), input.getBoolean("cellular"), input.getBoolean("expensive"), input.getBoolean("constrained"))
                    requireNetwork(binding)
                    val boundClient = client.newBuilder().socketFactory(binding.network.socketFactory)
                        .dns(object : okhttp3.Dns { override fun lookup(hostname: String): List<java.net.InetAddress> = binding.network.getAllByName(hostname).toList() })
                        .connectionPool(okhttp3.ConnectionPool(0, 1, TimeUnit.SECONDS)).build()
                    val call = boundClient.newCall(builder.build())
                    call.timeout().timeout(input.getLong("timeout").coerceIn(1, 60_000), TimeUnit.MILLISECONDS)
                    val id = next.getAndIncrement(); bindings[id] = binding; calls[id] = call
                    return ByteBuffer.allocate(8).putLong(id).array()
                } catch (error: Exception) { slots.release(); throw error }
            }
            25 -> {
                requireNetwork(checkNotNull(bindings[handle]))
                val response = checkNotNull(calls[handle]).execute()
                responses[handle] = response
                val headers = JSONObject()
                for (name in response.headers.names()) headers.put(name, response.headers.values(name).joinToString(", "))
                val metadata = JSONObject().put("status", response.code).put("headers", headers).toString().toByteArray()
                require(metadata.size <= 65_536); return metadata
            }
            26 -> {
                requireNetwork(checkNotNull(bindings[handle]))
                val stream = checkNotNull(responses[handle]).body?.byteStream() ?: return byteArrayOf()
                val buffer = ByteArray(65_536); val count = stream.read(buffer)
                return if (count < 0) byteArrayOf() else buffer.copyOf(count)
            }
            else -> error("unsupported operation")
        }
        return byteArrayOf()
    }
}
