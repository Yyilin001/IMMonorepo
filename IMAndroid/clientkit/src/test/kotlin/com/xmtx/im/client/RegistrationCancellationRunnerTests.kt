package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RegistrationCancellationRunnerTests {
    private class Transport : AccountTransport {
        val calls = mutableListOf<JsonObject>(); var error: Exception? = null
        override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
            assertEquals("/v2/device-credentials/cancel-registration", path); assertNull(accessToken); assertEquals(204, expectedStatus)
            calls += payload; error?.let { throw it }; return buildJsonObject {}
        }
    }
    @Test fun persistedBackoffDoesNotTreatLocalExpiryAsServerConfirmation() = runTest {
        val disk = MemorySecrets(); val store = DeviceRegistrationStore(disk) { 0 }; store.prepare("account").abandon()
        var now = 1_000_000L; val api = Transport().apply { error = IOException() }
        val runner = RegistrationCancellationRunner(store, api) { now }; runner.flushOnce()
        assertEquals(now + 2000, store.jobs().single().nextAttemptAt)
        now += 1999; runner.flushOnce(); assertEquals(1, api.calls.size)
        now++; api.error = ClientFailure.Http(429, retryAfter = "900000"); runner.flushOnce()
        val restored = DeviceRegistrationStore(disk).jobs().single(); assertEquals(now + 86_400_000, restored.nextAttemptAt)
        assertEquals(2, restored.attempts); assertEquals(api.calls.first(), api.calls.last())
        now = restored.nextAttemptAt; api.error = ClientFailure.Http(503); runner.flushOnce()
        assertEquals(now + 8000, store.jobs().single().nextAttemptAt)
    }
    @Test fun rawHttpGoneAndInvalidResponsesPauseUntilExplicitRetry() = runTest {
        for ((error, pause) in listOf(ClientFailure.Http(410) to RegistrationCancellationJob.Pause.InvalidRequest,
            ClientFailure.Http(401) to RegistrationCancellationJob.Pause.InvalidRequest,
            ClientFailure.Http(409) to RegistrationCancellationJob.Pause.InvalidRequest,
            ClientFailure.Protocol() to RegistrationCancellationJob.Pause.InvalidResponse)) {
            val store = DeviceRegistrationStore(MemorySecrets()) { 0 }; store.prepare("account").abandon()
            val api = Transport().apply { this.error = error }; val runner = RegistrationCancellationRunner(store, api) { 0 }
            runner.flushOnce(); assertEquals(pause, store.jobs().single().pause); runner.flushOnce(); assertEquals(1, api.calls.size)
            store.retryPaused(); api.error = null; runner.flushOnce(); assertFalse(store.hasWork())
            assertEquals(api.calls.first(), api.calls.last())
        }
    }
    @Test fun ownerWakesOnCommitAndScheduleAndCancellationDrainsBeforeReactivation() = runTest {
        val store = DeviceRegistrationStore(MemorySecrets()) { 0 }; val api = Transport().apply { error = IOException() }
        val runner = RegistrationCancellationRunner(store, api) { testScheduler.currentTime }
        val owner = backgroundScope.launch { runner.run() }; runCurrent()
        assertFailsWith<IllegalStateException> { runner.run() }
        store.prepare("account").abandon(); runCurrent(); assertEquals(1, api.calls.size)
        api.error = null; advanceTimeBy(2000); runCurrent(); assertFalse(store.hasWork()); owner.cancelAndJoin()
        val entered = CompletableDeferred<Unit>(); val draining = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val transport = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                entered.complete(Unit)
                try { awaitCancellation() } finally { withContext(NonCancellable) { draining.complete(Unit); release.await() } }
            }
        }
        store.prepare("account").abandon(); val before = store.jobs().single()
        val next = RegistrationCancellationRunner(store, transport) { 0 }; val task = launch { next.run() }
        entered.await(); task.cancel(); draining.await(); assertFalse(task.isCompleted)
        assertFailsWith<IllegalStateException> { next.run() }; release.complete(Unit); task.join()
        assertEquals(before, store.jobs().single())
    }
    @Test fun realHttpsAcceptsOnlyEmptyTerminalResponsesAndNeverSendsAccessCredentials() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.useHttps(serverTrust.sslSocketFactory(), false); server.start()
            val http = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).build()
            try { runBlocking { withTimeout(15_000) {
                for ((status, body) in listOf(204 to "", 410 to "", 204 to "{}", 410 to "{}", 200 to "{}", 200 to "invalid", 401 to "invalid", 429 to "{}", 503 to "")) {
                    server.enqueue(MockResponse().setResponseCode(status).setBody(body).setHeader("Content-Type", "application/json").setHeader("Retry-After", "12"))
                    val store = DeviceRegistrationStore(MemorySecrets()) { 0 }; val pending = store.prepare("account"); pending.abandon()
                    RegistrationCancellationRunner(store, AccountClient(server.url("/").toString(), http)) { 1_000_000 }.flushOnce()
                    val request = server.takeRequest(); assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("X-IM-Device-ID"))
                    assertEquals("no-store", request.getHeader("Cache-Control")); assertEquals("/v2/device-credentials/cancel-registration", request.path)
                    assertEquals(pending.cancellation.payload(), Json.parseToJsonElement(request.body.readUtf8()))
                    when {
                        (status == 204 || status == 410) && body.isEmpty() -> assertFalse(store.hasWork())
                        status == 204 || status == 410 || status == 200 -> assertEquals(RegistrationCancellationJob.Pause.InvalidResponse, store.jobs().single().pause)
                        status == 401 -> assertEquals(RegistrationCancellationJob.Pause.InvalidRequest, store.jobs().single().pause)
                        status == 429 -> assertEquals(1_012_000, store.jobs().single().nextAttemptAt)
                        status == 503 -> assertEquals(1_002_000, store.jobs().single().nextAttemptAt)
                    }
                }
            } } } finally { http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
        }
    }
}
