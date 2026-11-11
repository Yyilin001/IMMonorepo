package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

class SharedRefreshHttpTests {
    private fun fixture(block: suspend (AuthSession, MemorySecrets, AccountNetworkActivity, CountDownLatch, CountDownLatch, MockWebServer) -> Unit) {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val entered = CountDownLatch(1); val gate = CountDownLatch(1)
        MockWebServer().use { server ->
            server.useHttps(serverTrust.sslSocketFactory(), false); server.start()
            val http = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
                .addInterceptor { chain ->
                    val response = chain.proceed(chain.request()); entered.countDown()
                    if (!gate.await(10, TimeUnit.SECONDS)) { response.close(); error("Test gate timed out") }
                    response
                }.build()
            val owner = AccountNetworkActivity()
            try { runBlocking { withTimeout(15_000) {
                val store = MemorySecrets(); val fake = FakeAccount().apply { accessExpiry = 1 }
                val credential = AuthSession(store, fake) { 0 }.login("account", "password123456")
                val response = buildJsonObject {
                    put("userID", credential.userId.value); put("deviceID", credential.deviceId.value)
                    put("accessToken", "successor-access"); put("accessTokenExpiresAtMilliseconds", 200_000)
                    put("refreshCredential", "successor-refresh"); put("revocationCredential", credential.revocationCredential)
                    put("revocationCredentialExpiresAtMilliseconds", credential.revocationExpiresAt)
                }
                server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(response.toString()))
                val auth = AuthSession(store, AccountClient(server.url("/").toString(), http)) { 0 }
                try { block(auth, store, owner, entered, gate, server) }
                finally { gate.countDown(); owner.closeAndDrain() }
            } } } finally { gate.countDown(); http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown() }
        }
    }

    @Test fun cancelledWaitersLeaveRealHttpAndAdmissionAliveUntilPersistence() = fixture { auth, _, owner, entered, gate, server -> coroutineScope {
        val first = async { owner.access(auth) }
        assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
        val second = async { owner.access(auth) }; yield()
        first.cancelAndJoin(); second.cancelAndJoin()
        assertEquals(1, server.requestCount); assertEquals(1, owner.scheduler.snapshot().active)
        assertEquals(AuthSessionState.Refreshing, auth.currentState())
        gate.countDown()
        withTimeout(5000) { while (auth.current()!!.accessExpiresAt != 200_000L) delay(5) }
        assertEquals(0, owner.scheduler.snapshot().active)
        assertEquals(200_000, owner.access(auth).accessExpiresAt); assertEquals(1, server.requestCount)
    } }

    @Test fun accountCloseDrainsRealCallbackBeforeReleasingTheOwner() = fixture { auth, store, owner, entered, gate, server -> coroutineScope {
        val first = async { owner.access(auth) }
        assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
        first.cancelAndJoin(); val before = store.value
        val closing = async { owner.closeAndDrain() }; yield()
        assertFalse(closing.isCompleted); assertEquals(1, owner.scheduler.snapshot().active)
        gate.countDown(); closing.await()
        assertEquals(before, store.value); assertEquals(1, server.requestCount)
        val snapshot = owner.scheduler.snapshot()
        assertTrue(snapshot.closed); assertEquals(0, snapshot.active); assertEquals(0, snapshot.waiting)
        assertEquals(1, auth.current()!!.accessExpiresAt)
    } }
}
