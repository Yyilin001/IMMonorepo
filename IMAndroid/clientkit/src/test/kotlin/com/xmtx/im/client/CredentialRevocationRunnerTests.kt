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
import java.util.UUID
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class CredentialRevocationRunnerTests {
    private fun intent() = CredentialRevocationIntent(UserId("owner"), DeviceId(UUID.randomUUID().toString()),
        "imv2-revoke-v1.${"A".repeat(43)}", 1, UUID.randomUUID().toString().uppercase())
    private class Transport : AccountTransport {
        val calls = mutableListOf<JsonObject>()
        var error: Exception? = null
        override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
            assertEquals("/v2/device-credentials/revoke", path); assertNull(accessToken); assertEquals(204, expectedStatus)
            calls += payload; error?.let { throw it }; return buildJsonObject {}
        }
    }
    @Test fun serverResultsSettleOrPauseAndOnlyExplicitRetryResumesPausedWork() = runTest {
        for ((status, pause) in listOf(204 to null, 410 to null, 401 to CredentialRevocationJob.Pause.InvalidCredential,
            409 to CredentialRevocationJob.Pause.OperationConflict, 400 to CredentialRevocationJob.Pause.InvalidRequest,
            403 to CredentialRevocationJob.Pause.InvalidRequest)) {
            val queue = CredentialRevocationQueue(MemorySecrets()); val task = intent(); queue.enqueue(task)
            val transport = Transport().apply { error = if (status == 204) null else ClientFailure.Http(status) }
            val runner = CredentialRevocationRunner(queue, transport) { 100_000 }
            runner.flushOnce()
            assertEquals(setOf("credential", "operationID"), transport.calls.single().keys)
            assertEquals(task.operation, transport.calls.single().string("operationID"))
            if (pause == null) assertTrue(queue.jobs().isEmpty()) else {
                val paused = queue.jobs().single(); assertEquals(pause, paused.pause); assertEquals(1, paused.attempts)
                runner.flushOnce(); assertEquals(1, transport.calls.size)
                queue.retryPaused(); transport.error = null; runner.flushOnce(); assertTrue(queue.jobs().isEmpty())
                assertEquals(transport.calls.first(), transport.calls.last())
            }
        }
    }
    @Test fun backoffAndRetryAfterArePersistedWithoutUsingLocalCredentialExpiryAsSuccess() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk); val task = intent(); queue.enqueue(task)
        var clock = 1000L; val transport = Transport().apply { error = IOException() }
        val runner = CredentialRevocationRunner(queue, transport) { clock }
        runner.flushOnce(); assertEquals(3000, queue.jobs().single().nextAttemptAt)
        clock = 2999; runner.flushOnce(); assertEquals(1, transport.calls.size)
        clock = 3000; transport.error = ClientFailure.Http(429, retryAfter = "900000"); runner.flushOnce()
        val restored = CredentialRevocationQueue(disk).jobs().single()
        assertEquals(clock + 86_400_000, restored.nextAttemptAt); assertEquals(2, restored.attempts); assertNull(restored.pause)
        clock = restored.nextAttemptAt; transport.error = ClientFailure.Http(600); runner.flushOnce()
        assertEquals(clock + 8000, queue.jobs().single().nextAttemptAt)
        assertNull(queue.jobs().single().pause)
        assertTrue(transport.calls.all { it.string("operationID") == task.operation })
    }
    @Test fun invalidSuccessResponsePausesInsteadOfClaimingRevocation() = runTest {
        val queue = CredentialRevocationQueue(MemorySecrets()); queue.enqueue(intent())
        val runner = CredentialRevocationRunner(queue, Transport().apply { error = ClientFailure.Protocol() }) { 0 }
        runner.flushOnce(); assertEquals(CredentialRevocationJob.Pause.InvalidResponse, queue.jobs().single().pause)
    }
    @Test fun liveRunnerWakesOnCommitAndRetryScheduleAndRejectsConcurrentOwners() = runTest {
        val queue = CredentialRevocationQueue(MemorySecrets()); val transport = Transport().apply { error = IOException() }
        val runner = CredentialRevocationRunner(queue, transport) { testScheduler.currentTime }
        val owner = backgroundScope.launch { runner.run() }; runCurrent()
        assertFailsWith<IllegalStateException> { runner.run() }
        queue.enqueue(intent()); runCurrent(); assertEquals(1, transport.calls.size)
        advanceTimeBy(1999); runCurrent(); assertEquals(1, transport.calls.size)
        transport.error = null; advanceTimeBy(1); runCurrent(); assertEquals(2, transport.calls.size); assertTrue(queue.jobs().isEmpty())
        owner.cancelAndJoin()
        val next = backgroundScope.launch { runner.run() }; runCurrent(); queue.enqueue(intent()); runCurrent()
        assertEquals(3, transport.calls.size); next.cancelAndJoin()
    }
    @Test fun cancellationDrainsTheTransportAndRetainsAnUnchangedJobBeforeReactivation() = runTest {
        val queue = CredentialRevocationQueue(MemorySecrets()); queue.enqueue(intent()); val original = queue.jobs().single()
        val entered = CompletableDeferred<Unit>(); val draining = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val transport = object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
                entered.complete(Unit)
                try { awaitCancellation() } finally { withContext(NonCancellable) { draining.complete(Unit); release.await() } }
            }
        }
        val runner = CredentialRevocationRunner(queue, transport) { 0 }
        val owner = launch { runner.run() }; entered.await(); owner.cancel(); draining.await()
        assertFalse(owner.isCompleted); assertFailsWith<IllegalStateException> { runner.run() }
        release.complete(Unit); owner.join(); assertEquals(original, queue.jobs().single())
    }
    @Test fun persistentFailureStopsTheRunnerAndPreservesTheUnsettledJob() = runTest {
        val disk = MemorySecrets(); val queue = CredentialRevocationQueue(disk); queue.enqueue(intent())
        val original = disk.value; disk.failWrite = true
        val runner = CredentialRevocationRunner(queue, Transport().apply { error = IOException() }) { 0 }
        assertFailsWith<CredentialRecoveryFailure> { runner.run() }; assertEquals(original, disk.value)
        disk.failWrite = false; CredentialRevocationRunner(queue, Transport()) { 0 }.flushOnce(); assertTrue(queue.jobs().isEmpty())
    }
    @Test fun realHttpsUsesOnlyPurposeLimitedAuthorityAndPreservesServerStatusSemantics() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.useHttps(serverTrust.sslSocketFactory(), false); server.start()
            val http = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).build()
            try { runBlocking { withTimeout(15_000) {
                for (status in listOf(204, 401, 409, 410, 429, 503, 200)) {
                    server.enqueue(MockResponse().setResponseCode(status).setHeader("Retry-After", "12"))
                    val queue = CredentialRevocationQueue(MemorySecrets()); val task = intent(); queue.enqueue(task)
                    CredentialRevocationRunner(queue, AccountClient(server.url("/").toString(), http)) { 0 }.flushOnce()
                    val request = server.takeRequest(); assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("X-IM-Device-ID"))
                    assertEquals("no-store", request.getHeader("Cache-Control")); assertEquals("/v2/device-credentials/revoke", request.path)
                    val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
                    assertEquals(setOf("credential", "operationID"), body.keys); assertEquals(task.operation, body.string("operationID"))
                    when (status) {
                        204, 410 -> assertTrue(queue.jobs().isEmpty())
                        401 -> assertEquals(CredentialRevocationJob.Pause.InvalidCredential, queue.jobs().single().pause)
                        409 -> assertEquals(CredentialRevocationJob.Pause.OperationConflict, queue.jobs().single().pause)
                        429 -> assertEquals(12000, queue.jobs().single().nextAttemptAt)
                        503 -> assertEquals(2000, queue.jobs().single().nextAttemptAt)
                        200 -> assertEquals(CredentialRevocationJob.Pause.InvalidResponse, queue.jobs().single().pause)
                    }
                }
            } } } finally { http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
        }
    }
}
