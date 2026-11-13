package com.xmtx.im.swiftprobe

import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Before
import com.xmtx.im.swiftplatform.AndroidRuntimePlatform
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.system.measureTimeMillis

class SwiftProbeTests {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private var evidence = JSONObject()

    @get:Rule val report = object : TestWatcher() {
        override fun succeeded(description: Description) { save(description, "passed", null) }
        override fun failed(error: Throwable, description: Description) { save(description, "failed", error.toString()) }
        private fun save(description: Description, status: String, error: String?) {
            val file = File(context.filesDir, "probe-results.json")
            val previous = if (file.exists()) JSONObject(file.readText()) else JSONObject()
            previous.put("api", Build.VERSION.SDK_INT).put("abi", Build.SUPPORTED_ABIS.first())
                .put("fingerprint", Build.FINGERPRINT)
            val tests = previous.optJSONObject("tests") ?: JSONObject()
            tests.put(description.methodName, JSONObject().put("status", status).put("error", error).put("evidence", evidence))
            previous.put("tests", tests)
            file.writeText(previous.toString(2))
        }
    }

    @Before fun installAndroidPlatform() {
        NativeProbe.active() // Load the embedding Swift library before the platform JNI entry point.
        AndroidRuntimePlatform.install(context)
    }

    @Test fun androidKeystoreAtomicRecordAndTamper() = runBlocking<Unit> {
        val name = "phase3-tamper"
        try {
            evidence = SwiftProbe.execute(JSONObject().put("operation", "android_credentials").put("path", name))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
            val file = File(context.noBackupFilesDir, "im-swift-secrets-v1/$name.sealed")
            val encrypted = file.readBytes()
            assertFalse(String(encrypted, Charsets.ISO_8859_1).contains("phase3-fixture-access"))
            encrypted[encrypted.lastIndex] = (encrypted.last().toInt() xor 1).toByte(); file.writeBytes(encrypted)
            val load = SwiftProbe.execute(JSONObject().put("operation", "android_credential_load").put("path", name))
            assertEquals("error", load.getString("outcome"))
            assertEquals("malformedRecord", load.getJSONObject("values").getString("error"))
            evidence.put("tamperRejected", true).put("noPlaintext", true)
        } finally { SwiftProbe.execute(JSONObject().put("operation", "android_credential_delete").put("path", name)) }
    }

    @Test fun androidKeystoreMissingKeyIsNotAbsence() = runBlocking<Unit> {
        val name = "phase3-key-loss"
        try {
            val saved = SwiftProbe.execute(JSONObject().put("operation", "android_credentials").put("path", name))
            assertEquals(saved.toString(), "ok", saved.getString("outcome"))
            java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("com.xmtx.im.swift.$name.v1") }
            evidence = SwiftProbe.execute(JSONObject().put("operation", "android_credential_load").put("path", name))
            assertEquals("error", evidence.getString("outcome"))
            assertEquals("permanentlyInvalidated", evidence.getJSONObject("values").getString("error"))
        } finally {
            val deleted = SwiftProbe.execute(JSONObject().put("operation", "android_credential_delete").put("path", name))
            assertEquals(deleted.toString(), "ok", deleted.getString("outcome"))
        }
    }

    @Test fun androidTLS13TrustedRoundTrip() = runBlocking<Unit> {
        Phase3Peer(context, InstrumentationRegistry.getInstrumentation().context).use { peer ->
            peer.run { accept().use { socket ->
                val bytes = ByteArray(6); java.io.DataInputStream(socket.inputStream).readFully(bytes)
                socket.outputStream.write(bytes)
            } }
            evidence = SwiftProbe.execute(JSONObject().put("operation", "android_tls").put("url", peer.url))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome")); peer.await()
        }
    }

    @Test fun androidTLSRejectsUnknownCAHostnameAndTLS12() = runBlocking<Unit> {
        for (mode in listOf("ca", "hostname", "tls12")) {
            Phase3Peer(context, InstrumentationRegistry.getInstrumentation().context, trusted = mode != "ca", tls12 = mode == "tls12").use { peer ->
                peer.run { runCatching { accept().use { it.inputStream.read() } } }
                val url = if (mode == "hostname") peer.url.replace("localhost", "127.0.0.1") else peer.url
                val result = SwiftProbe.execute(JSONObject().put("operation", "android_tls").put("url", url))
                assertEquals("$mode: $result", "error", result.getString("outcome")); peer.await()
                evidence.put(mode, "rejected")
            }
        }
    }

    @Test fun androidTLSCancellationDrainsBlockedRead() = runBlocking<Unit> {
        Phase3Peer(context, InstrumentationRegistry.getInstrumentation().context).use { peer ->
            val read = CountDownLatch(1)
            peer.run { accept().use { socket ->
                val bytes = ByteArray(6); java.io.DataInputStream(socket.inputStream).readFully(bytes); read.countDown()
                assertEquals(-1, socket.inputStream.read())
            } }
            val task = launch { SwiftProbe.execute(JSONObject().put("operation", "android_tls_wait").put("url", peer.url)) }
            withTimeout(10000) { while (read.count != 0L) delay(10) }
            val elapsed = measureTimeMillis { task.cancelAndJoin() }
            assertTrue("cancel took $elapsed ms", elapsed < 2000); peer.await()
            evidence.put("cancelMilliseconds", elapsed).put("physicalDisconnect", true)
        }
    }

    @Test fun androidTLSCancellationDrainsStalledHandshake() = runBlocking<Unit> {
        ServerSocket(0).use { listener ->
            val accepted = CountDownLatch(1)
            val ended = CountDownLatch(1)
            val server = thread {
                listener.accept().use { socket ->
                    socket.soTimeout = 10000; accepted.countDown()
                    try { while (socket.inputStream.read() >= 0) { /* Drain ClientHello until physical close. */ } }
                    finally { ended.countDown() }
                }
            }
            val task = launch { SwiftProbe.execute(JSONObject().put("operation", "android_tls_wait")
                .put("url", "tls://localhost:${listener.localPort}")) }
            withTimeout(10000) { while (accepted.count != 0L) delay(10) }
            val elapsed = measureTimeMillis { task.cancelAndJoin() }
            assertTrue("handshake cancel took $elapsed ms", elapsed < 2000)
            assertTrue(ended.await(2, TimeUnit.SECONDS)); server.join(2000)
            evidence.put("cancelMilliseconds", elapsed).put("physicalDisconnect", true)
        }
    }

    @Test fun androidSharedRuntimeAuthenticationSyncAndReconnect() = runBlocking<Unit> {
        val directory = File(context.noBackupFilesDir, "phase3-session-${System.nanoTime()}").apply { mkdirs() }
        try {
            Phase3Peer(context, InstrumentationRegistry.getInstrumentation().context).use { peer ->
                peer.run { session() }
                evidence = SwiftProbe.execute(JSONObject().put("operation", "android_session").put("url", peer.url)
                    .put("path", File(directory, "state.sqlite").path))
                assertEquals(evidence.toString(), "ok", evidence.getString("outcome")); peer.await()
                assertEquals("2", evidence.getJSONObject("values").getString("durableSequence"))
            }
        } finally { directory.deleteRecursively() }
    }

    @After fun noLeakedSwiftHandles() {
        assertEquals("Swift handles still owned after test", 0, NativeProbe.active())
        assertEquals("Android sockets still owned after test", 0, AndroidRuntimePlatform.install(context).activeConnectionCount)
    }

    @Test fun dependenciesDatabaseAndFTS5() = runBlocking<Unit> {
        val path = File(context.noBackupFilesDir, "probe-消息.sqlite")
        try {
            evidence = SwiftProbe.execute(JSONObject().put("operation", "dependencies").put("path", path.path))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
            assertEquals("true", evidence.getJSONObject("values").getString("atomicRollback"))
        } finally { listOf(path, File("${path.path}-wal"), File("${path.path}-shm")).forEach { it.delete() } }
    }

    @Test fun productionRuntimeAndUnicodeSearch() = runBlocking<Unit> {
        val path = File(context.noBackupFilesDir, "runtime-search.sqlite")
        try {
            evidence = SwiftProbe.execute(JSONObject().put("operation", "runtime").put("path", path.path))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
            assertEquals("true", evidence.getJSONObject("values").getString("exclusiveWriter"))
            assertEquals("true", evidence.getJSONObject("values").getString("reopen"))
        } finally { listOf(path, File("${path.path}-wal"), File("${path.path}-shm"), File("${path.path}.lock")).forEach { it.delete() } }
    }

    @Test fun productionHTTPBoundsAndRedirects() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setBody("共享运行时 HTTP"))
            evidence = SwiftProbe.execute(http(server.url("/").toString()).put("operation", "runtime_http"))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
            assertEquals("共享运行时 HTTP", evidence.getJSONObject("values").getString("body"))
            assertEquals("true", evidence.getJSONObject("values").getString("permitDrained"))
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", server.url("/forbidden")))
            evidence = SwiftProbe.execute(http(server.url("/redirect").toString()).put("operation", "runtime_http"))
            assertEquals("302", evidence.getJSONObject("values").getString("status"))
            for (chunked in listOf(false, true)) {
                val response = MockResponse()
                if (chunked) response.setChunkedBody("x".repeat(32768), 512) else response.setBody("x".repeat(32768))
                server.enqueue(response)
                evidence = SwiftProbe.execute(http(server.url("/large").toString()).put("operation", "runtime_http").put("maximumBytes", 1024))
                assertError("oversized")
            }
            assertEquals(4, server.requestCount)
            evidence.put("body", true).put("redirectRejected", true).put("declaredAndChunkedCap", true)
        }
    }

    @Test fun productionHTTPDeadlineAndCancellationDrain() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("late").setHeadersDelay(2, TimeUnit.SECONDS))
            server.start()
            val elapsed = measureTimeMillis {
                evidence = SwiftProbe.execute(http(server.url("/").toString()).put("operation", "runtime_http").put("deadlineMilliseconds", 150))
            }
            assertError("deadline")
            assertTrue("Production deadline did not drain: $elapsed", elapsed < 2000)
        }
        StreamingFixture().use { server ->
            val job = async { SwiftProbe.execute(http(server.url).put("operation", "runtime_http").put("maximumBytes", 16777216)) }
            withTimeout(3000) { while (server.headersSent.count != 0L) delay(10) }
            delay(100)
            val elapsed = measureTimeMillis { withTimeout(2000) { job.cancelAndJoin() } }
            withTimeout(3000) { while (server.disconnected.count != 0L) delay(10) }
            evidence.put("cancelAndDrainMs", elapsed).put("serverObservedDisconnect", true)
            assertTrue(job.isCancelled)
        }
    }

    @Test fun productionHTTPUsesDefaultTLS() = runBlocking<Unit> {
        evidence = SwiftProbe.execute(http("https://www.swift.org/").put("operation", "runtime_http").put("maximumBytes", 1048576).put("deadlineMilliseconds", 20000))
        assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
        assertEquals("200", evidence.getJSONObject("values").getString("status"))
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("127.0.0.1").build()
        val certificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        MockWebServer().use { server ->
            server.useHttps(certificates.sslSocketFactory(), false)
            server.enqueue(MockResponse().setBody("must not accept"))
            server.start()
            val rejected = SwiftProbe.execute(http(server.url("/").toString()).put("operation", "runtime_http"))
            assertEquals(rejected.toString(), "error", rejected.getString("outcome"))
            assertEquals(0, server.requestCount)
            evidence.put("selfSignedRejected", rejected)
        }
    }

    @Test fun httpBodyAndStatus() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("中文 HTTP response").setHeader("Content-Type", "text/plain; charset=utf-8"))
            server.start()
            evidence = SwiftProbe.execute(http(server.url("/").toString()))
            assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
            assertEquals("中文 HTTP response", evidence.getJSONObject("values").getString("body"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun redirectsAreNotFollowed() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", server.url("/must-not-request")))
            evidence = SwiftProbe.execute(http(server.url("/redirect").toString()))
            assertEquals("302", evidence.getJSONObject("values").getString("status"))
            assertEquals("true", evidence.getJSONObject("values").getString("redirectRejected"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun declaredOversizeRejected() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("x".repeat(32_768)))
            server.start()
            evidence = SwiftProbe.execute(http(server.url("/").toString()).put("maximumBytes", 1024))
            assertError("oversized")
        }
    }

    @Test fun chunkedOversizeRejected() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setChunkedBody("x".repeat(32_768), 512))
            server.start()
            evidence = SwiftProbe.execute(http(server.url("/").toString()).put("maximumBytes", 1024))
            assertError("oversized")
        }
    }

    @Test fun absoluteDeadlineCancelsRequest() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("late").setHeadersDelay(2, TimeUnit.SECONDS))
            server.start()
            val elapsed = measureTimeMillis {
                evidence = SwiftProbe.execute(http(server.url("/").toString()).put("deadlineMilliseconds", 150))
            }
            assertError("deadline")
            evidence.put("elapsedMs", elapsed)
            assertTrue("Deadline did not drain promptly: $elapsed", elapsed < 2000)
        }
    }

    @Test fun kotlinCancellationDrainsSwiftSleep() = runBlocking<Unit> {
        val elapsed = measureTimeMillis {
            repeat(30) {
                val job = launch { SwiftProbe.execute(JSONObject().put("operation", "sleep")) }
                delay(10)
                withTimeout(2000) { job.cancelAndJoin() }
                assertEquals(0, NativeProbe.active())
            }
        }
        evidence.put("iterations", 30).put("elapsedMs", elapsed)
    }

    @Test fun kotlinCancellationDrainsSwiftStream() = runBlocking<Unit> {
        repeat(20) {
            val job = launch { SwiftProbe.execute(JSONObject().put("operation", "stream")) }
            delay(20)
            withTimeout(2000) { job.cancelAndJoin() }
            assertEquals(0, NativeProbe.active())
        }
        evidence.put("iterations", 20).put("producerDrainedBeforeReturn", true)
    }

    @Test fun nativeCancelIsIdempotentAndReleaseRequiresCompletion() = runBlocking<Unit> {
        val handle = NativeProbe.start(JSONObject().put("operation", "sleep").toString().toByteArray())
        assertTrue(handle > 0)
        assertEquals(0, NativeProbe.release(handle))
        try {
            repeat(5) { NativeProbe.cancel(handle) }
            val result = withTimeout(2000) {
                var bytes = NativeProbe.poll(handle)
                while (bytes == null) { delay(10); bytes = NativeProbe.poll(handle) }
                JSONObject(bytes.toString(Charsets.UTF_8))
            }
            evidence = result
            assertEquals("cancelled", result.getString("outcome"))
        } finally { NativeProbe.cancel(handle); assertEquals(1, NativeProbe.release(handle)) }
        assertNull(NativeProbe.poll(handle))
        NativeProbe.cancel(handle)
        assertEquals(0, NativeProbe.release(handle))
    }

    @Test fun cancellationClosesPhysicalHTTPStream() = runBlocking<Unit> {
        StreamingFixture().use { server ->
            val job = async { SwiftProbe.execute(http(server.url).put("maximumBytes", 16_777_216)) }
            withTimeout(3000) { while (server.headersSent.count != 0L) delay(10) }
            delay(100)
            val elapsed = measureTimeMillis { withTimeout(2000) { job.cancelAndJoin() } }
            withTimeout(3000) { while (server.disconnected.count != 0L) delay(10) }
            evidence.put("cancelAndDrainMs", elapsed).put("serverObservedDisconnect", true)
            assertTrue(job.isCancelled)
        }
    }

    @Test fun defaultTrustRejectsSelfSignedTLS() = runBlocking<Unit> {
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("127.0.0.1").build()
        val certificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        MockWebServer().use { server ->
            server.useHttps(certificates.sslSocketFactory(), false)
            server.enqueue(MockResponse().setBody("must not accept"))
            server.start()
            evidence = SwiftProbe.execute(http(server.url("/").toString()))
            assertEquals(evidence.toString(), "error", evidence.getString("outcome"))
            // A generic network error is not evidence of certificate validation.
            val error = evidence.getJSONObject("values").getString("error")
            assertTrue(evidence.toString(), error.contains("certificate problem: self signed certificate"))
            assertEquals(0, server.requestCount)
        }
    }

    @Test fun defaultTrustAcceptsPublicHTTPS() = runBlocking<Unit> {
        evidence = SwiftProbe.execute(http("https://www.swift.org/").put("maximumBytes", 1_048_576).put("deadlineMilliseconds", 20_000))
        assertEquals(evidence.toString(), "ok", evidence.getString("outcome"))
        assertEquals("200", evidence.getJSONObject("values").getString("status"))
    }

    private fun http(url: String) = JSONObject().put("operation", "http").put("url", url.replace("localhost", "127.0.0.1"))
    private fun assertError(kind: String) {
        assertEquals(evidence.toString(), "error", evidence.getString("outcome"))
        assertTrue(evidence.toString(), evidence.getJSONObject("values").getString("error").contains(kind))
    }
}

private class StreamingFixture : AutoCloseable {
    private val server = ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
    val url = "http://127.0.0.1:${server.localPort}/stream"
    val headersSent = CountDownLatch(1)
    val disconnected = CountDownLatch(1)
    @Volatile private var client: Socket? = null
    private val worker = thread(name = "swift-probe-stream") {
        try {
            server.accept().use { socket ->
                client = socket
                val reader = socket.getInputStream().bufferedReader()
                while (!reader.readLine().isNullOrEmpty()) { /* consume request headers */ }
                val output = socket.getOutputStream()
                output.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".toByteArray())
                output.flush()
                headersSent.countDown()
                repeat(1000) {
                    output.write(("200\r\n" + "x".repeat(512) + "\r\n").toByteArray())
                    output.flush()
                    Thread.sleep(10)
                }
            }
        } catch (_: java.io.IOException) { disconnected.countDown() }
    }
    override fun close() { client?.close(); server.close(); worker.join(2000) }
}
