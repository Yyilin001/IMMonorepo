package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ScheduledHttpTests {
    private fun fixture(block:suspend (MockWebServer,OkHttpClient)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use {server->
            server.useHttps(serverTrust.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try {runBlocking {withTimeout(15000) {block(server,http)}}}
            finally {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
        }
    }
    private suspend fun credentials()=AuthSession(MemorySecrets(),FakeAccount()) {0}.login("account","password123456")
    private fun MockWebServer.json()=enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{}"))
    private suspend fun waitForWaiting(scheduler:AccountWorkScheduler,count:Int) {
        withTimeout(5000) {while(scheduler.snapshot().waiting!=count) delay(5)}
    }
    @Test fun `real HTTP timeouts degrade only their activation and complete bodies restore admission`()=fixture {server,http->coroutineScope {
        val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
        val client=AccountClient(server.url("/").toString(),http.newBuilder().readTimeout(200,TimeUnit.MILLISECONDS).build())
        val credential=credentials();val held=mutableListOf<AccountWorkScheduler.Permit>()
        suspend fun request()=withContext(NetworkWorkScope(scheduler,NetworkWorkContext("account"))) {client.request("/v2/quality",credential)}
        try {
            repeat(2) {window->repeat(5) {
                clock.set(window*10_000L+it*1000)
                server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{}").setBodyDelay(400,TimeUnit.MILLISECONDS))
                assertFailsWith<java.net.SocketTimeoutException> {request()}
            }}
            clock.set(20_000);server.json();request()
            assertEquals(NetworkQualityObserver.Quality.Degraded,scheduler.serviceQuality("account"))
            repeat(3) {held+=scheduler.acquire(NetworkWorkContext("account"))}
            server.json();val queued=async {request()};waitForWaiting(scheduler,1)
            // Authentication and a different service remain available while ordinary account work waits.
            held+=scheduler.acquire(NetworkWorkContext("another-service"))
            val replacement=AccountWorkScheduler()
            try {
                server.json()
                withContext(NetworkWorkScope(replacement,NetworkWorkContext("account"))) {client.request("/v2/new-activation",credential)}
                assertEquals(NetworkQualityObserver.Quality.Normal,replacement.serviceQuality("account"))
            } finally {replacement.closeAndDrain()}
            server.json();withContext(NetworkWorkScope(scheduler,NetworkWorkContext("account"))) {client.post("/v2/account-auth/check",buildJsonObject {})}
            assertFalse(queued.isCompleted)
            held.forEach {scheduler.release(it)};held.clear();queued.await()
            repeat(3) {window->repeat(20) {index->
                clock.set(100_000+window*10_000L+index*100)
                if(index%2==0) {server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{bad"));assertFails {request()}}
                else {server.json();request()}
            }}
            assertEquals(NetworkQualityObserver.Quality.Degraded,scheduler.serviceQuality("account"))
            clock.set(130_000);server.json();request();assertEquals(NetworkQualityObserver.Quality.Normal,scheduler.serviceQuality("account"))
            repeat(4) {held+=scheduler.acquire(NetworkWorkContext("account"))}
        } finally {held.forEach {scheduler.release(it)};scheduler.closeAndDrain()}
    }}
    @Test fun `cooldown body timeouts local caps and caller cancellation are not bad network samples`()=fixture {server,http->coroutineScope {
        val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
        val client=AccountClient(server.url("/").toString(),http.newBuilder().readTimeout(200,TimeUnit.MILLISECONDS).build(),scheduler)
        val credential=credentials()
        try {
            repeat(5) {clock.set(it*1000L);scheduler.recordQuality(NetworkQualityObserver.Sample.Timeout,"account")}
            repeat(5) {index->
                clock.set(10_000+index*1000L)
                server.enqueue(MockResponse().setResponseCode(if(index%2==0) 429 else 503).setHeader("Content-Type","application/json").setBody("{}").setBodyDelay(400,TimeUnit.MILLISECONDS))
                assertFailsWith<java.net.SocketTimeoutException> {client.request("/v2/cooldown",credential)}
                server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("12345"))
                assertFailsWith<ClientFailure.Protocol> {client.request("/v2/capped",credential,maximumBytes=1)}
                // Cancel after headers have reached the client, while the body is still pending.
                val arrived=CompletableDeferred<Unit>()
                val gated=http.newBuilder().addNetworkInterceptor {chain->chain.proceed(chain.request()).also {arrived.complete(Unit)}}.build()
                server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{}").setBodyDelay(400,TimeUnit.MILLISECONDS))
                val cancelled=launch {AccountClient(server.url("/").toString(),gated,scheduler).request("/v2/cancelled",credential)}
                arrived.await();cancelled.cancelAndJoin()
            }
            clock.set(20_000);server.json();client.request("/v2/complete",credential)
            assertEquals(NetworkQualityObserver.Quality.Normal,scheduler.serviceQuality("account"))
        } finally {scheduler.closeAndDrain()}
    }}
    @Test fun `admission budget expiry does not become a transmission timeout sample`()=runTest {
        var clock=0L;val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1),nowMillis={clock})
        val client=AccountClient("https://localhost/",scheduler=scheduler);val credential=credentials()
        val held=scheduler.acquire(NetworkWorkContext("account"))
        try {
            repeat(5) {clock=it*1000L;scheduler.recordQuality(NetworkQualityObserver.Sample.Timeout,"account")}
            repeat(5) {clock=10_000+it*1000L;assertFailsWith<AccountRequestDeadlineExceeded> {client.request("/v2/never-sent",credential)}}
            clock=20_000;scheduler.recordQuality(NetworkQualityObserver.Sample.Success,"account")
            assertEquals(NetworkQualityObserver.Quality.Normal,scheduler.serviceQuality("account"));assertEquals(0,scheduler.snapshot().waiting)
        } finally {scheduler.release(held);scheduler.closeAndDrain()}
    }
    @Test fun `domain retries spend the selected account quota while initial requests and auth still proceed`()=fixture {server,http->coroutineScope {
        val clock=java.util.concurrent.atomic.AtomicLong(0);val s=AccountWorkScheduler(nowMillis=clock::get)
        val client=AccountClient(server.url("/").toString(),http,s);val credential=credentials()
        try {
            repeat(8) {server.json()}
            repeat(5) {withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {client.request("/v2/retry",credential)}}
            val next=async(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {client.request("/v2/sixth",credential)}
            waitForWaiting(s,1);assertEquals(5,server.requestCount)
            withContext(NetworkWorkIntent(NetworkWorkPriority.Interactive,false)) {assertEquals(200,client.request("/v2/initial",credential).status)}
            val ordered=s.acquire(NetworkWorkContext("another-service",orderingKey="busy-command"))
            try {withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,true,"busy-command")) {client.post("/v2/account-auth/test",buildJsonObject {})}}
            finally {s.release(ordered)}
            assertEquals(7,server.requestCount);assertFalse(next.isCompleted)
            clock.set(2000);s.setDegraded(false);assertEquals(200,next.await().status);assertEquals(8,server.requestCount)
        } finally {s.closeAndDrain()}
    }}
    @Test fun `cancelled callback keeps physical permit until drain while authentication proceeds`()=fixture {server,http->coroutineScope {
        val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
        val entered=CountDownLatch(1);val gate=CountDownLatch(1)
        val blocked=http.newBuilder().addInterceptor {chain->
            val result=chain.proceed(chain.request())
            if(chain.request().url.encodedPath=="/v2/held") {
                entered.countDown()
                if(!gate.await(10,TimeUnit.SECONDS)) {result.close();error("Test gate timed out")}
            }
            result
        }.build()
        val client=AccountClient(server.url("/").toString(),blocked,s);val credential=credentials()
        server.json();server.json();server.json()
        val first=launch {client.request("/v2/held",credential)}
        try {
            assertTrue(withContext(Dispatchers.IO) {entered.await(5,TimeUnit.SECONDS)})
            first.cancel()
            val next=async {client.request("/v2/next",credential)}
            waitForWaiting(s,1)
            assertFalse(first.isCompleted);assertEquals(1,s.snapshot().active)
            assertEquals(buildJsonObject {},client.post("/v2/account-auth/test",buildJsonObject {}))
            assertEquals(2,server.requestCount);assertFalse(next.isCompleted)
            gate.countDown();first.join();assertEquals(200,next.await().status)
            assertEquals(3,server.requestCount);assertEquals(0,s.snapshot().active)
        } finally {gate.countDown();first.cancelAndJoin();s.closeAndDrain()}
    }}
    @Test fun `scope reaches only leaf and cancelled admission never sends a request`()=fixture {server,http->coroutineScope {
        val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
        val held=s.acquire(NetworkWorkContext("account"));val client=AccountClient(server.url("/").toString(),http)
        val credential=credentials()
        val request=launch(NetworkWorkScope(s,NetworkWorkContext("domain-step",NetworkWorkPriority.Recovery,NetworkWorkKind.Upload,orderingKey="original-command",isRetry=true))) {
            client.request("/v2/queued",credential)
        }
        waitForWaiting(s,1)
        assertEquals(0,s.snapshot().waitingByteTransfers);assertEquals(0,server.requestCount)
        request.cancelAndJoin();assertEquals(0,s.snapshot().waiting);s.release(held)
        server.json()
        withContext(NetworkWorkScope(s,NetworkWorkContext("domain-step"))) {assertEquals(200,client.request("/v2/ready",credential).status)}
        assertEquals(1,server.requestCount);assertEquals(0,s.snapshot().active);s.closeAndDrain()
    }}
    @Test fun `closed admission is not replayed or transmitted`()=fixture {server,http->
        val s=AccountWorkScheduler();val client=AccountClient(server.url("/").toString(),http,s);s.closeAndDrain()
        val failure=assertFailsWith<AccountRequestAdmissionFailure> {client.post("/v2/account-auth/test",buildJsonObject {})}
        assertEquals(AccountWorkScheduler.Rejection.Closed,failure.reason);assertEquals(0,server.requestCount)
    }
    @Test fun `error headers impose shared service cooldown even when body is invalid`()=fixture {server,http->coroutineScope {
        val clock=java.util.concurrent.atomic.AtomicLong(0)
        val s=AccountWorkScheduler(nowMillis=clock::get)
        val client=AccountClient(server.url("/").toString(),http,s);val credential=credentials()
        server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After","60").setHeader("Content-Type","application/json").setBody("{invalid"))
        assertFails {client.request("/v2/failure",credential)}
        val next=async {client.request("/v2/next",credential)};waitForWaiting(s,1)
        assertEquals(1,server.requestCount)
        server.json();assertEquals(buildJsonObject {},client.post("/v2/account-auth/test",buildJsonObject {}))
        assertFalse(next.isCompleted);assertEquals(2,server.requestCount)
        server.json();clock.set(60_000);s.setDegraded(false)
        assertEquals(200,next.await().status);assertEquals(3,server.requestCount);s.closeAndDrain()
    }}

    @Test fun `account refresh shares reserved channel and logout works after activation retirement`()=fixture {server,http->coroutineScope {
        val owner=AccountNetworkActivity(AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1)))
        val s=owner.scheduler;val client=AccountClient(server.url("/").toString(),http)
        val secrets=MemorySecrets();val initial=AuthSession(secrets,FakeAccount()) {0}.login("account","password123456")
        val auth=AuthSession(secrets,client) {100_000}
        val refreshed=buildJsonObject {
            put("userID",initial.userId.value);put("deviceID",initial.deviceId.value)
            put("accessToken","rotated-access");put("accessTokenExpiresAtMilliseconds",1_000_000)
            put("refreshCredential",initial.refreshCredential);put("revocationCredential",initial.revocationCredential)
            put("revocationCredentialExpiresAtMilliseconds",initial.revocationExpiresAt)
        }
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(refreshed.toString()));server.json()
        val ordinary=s.acquire(NetworkWorkContext("account"))
        val authentication=s.acquire(NetworkWorkContext("authentication",kind=NetworkWorkKind.Authentication))
        val api=owner.authenticated(auth,client,initial.userId,initial.deviceId)
        val request=async {api.request("/v2/business")};waitForWaiting(s,1)
        assertEquals(0,server.requestCount)
        s.release(authentication)
        assertEquals("/v2/device-credentials/refresh",withContext(Dispatchers.IO) {server.takeRequest(5,TimeUnit.SECONDS)}?.path)
        withTimeout(5000) {while(auth.current()?.accessToken!="rotated-access") delay(5)}
        waitForWaiting(s,1);assertEquals(1,server.requestCount);assertEquals(1,s.snapshot().active)
        s.release(ordinary);assertEquals(200,request.await().status);owner.closeAndDrain()
        server.enqueue(MockResponse().setResponseCode(204));auth.logout();assertNull(secrets.value)
        assertEquals(3,server.requestCount)
    }}

}
