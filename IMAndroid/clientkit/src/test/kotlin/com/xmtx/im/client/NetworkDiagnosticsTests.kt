package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

class NetworkDiagnosticsTests {
    private fun fixture(block:suspend (MockWebServer,OkHttpClient)->Unit) {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTrust=HandshakeCertificates.Builder().heldCertificate(cert).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        MockWebServer().use {server->
            server.useHttps(serverTrust.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try {runBlocking {withTimeout(15_000) {block(server,http)}}}
            finally {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
        }
    }
    private suspend fun credentials()=AuthSession(MemorySecrets(),FakeAccount()) {0}.login("account","password123456")
    private fun MockWebServer.json(body:String="{}",status:Int=200)=enqueue(MockResponse().setResponseCode(status).setHeader("Content-Type","application/json").setBody(body))

    @Test fun `real TLS phases reuse and caller listeners survive account recording`()=fixture {server,http->
        val starts=AtomicInteger();val ends=AtomicInteger()
        val observed=http.newBuilder().eventListener(object:EventListener() {
            override fun callStart(call:Call) {starts.incrementAndGet()}
            override fun callEnd(call:Call) {ends.incrementAndGet()}
        }).build()
        val owner=AccountWorkScheduler();val client=AccountClient(server.url("/").toString(),observed,owner)
        try {
            val credential=credentials();server.json();server.json()
            client.request("/v2/first",credential)
            val first=owner.networkDiagnostics.snapshot().http.single()
            assertEquals(NetworkMetric.Certainty.ResponseReceived,first.certainty)
            assertEquals(2,first.receivedBytes);assertEquals(200,first.statusCode);assertEquals(1,first.transactionCount)
            assertNull(first.reusedConnection);assertNotNull(first.phases.tlsNanos);assertNotNull(first.phases.connectNanos)
            assertNotNull(first.phases.requestNanos);assertNotNull(first.phases.responseNanos)
            withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {client.request("/v2/second",credential)}
            val second=owner.networkDiagnostics.snapshot().http.last()
            assertTrue(second.reusedConnection!!);assertNull(second.phases.connectNanos);assertNull(second.phases.tlsNanos)
            assertNull(second.phases.dnsNanos);assertEquals(NetworkWorkPriority.Recovery,second.priority);assertTrue(second.isRetry)
            assertEquals(2,starts.get());assertEquals(2,ends.get());assertEquals(2,owner.networkDiagnostics.snapshot().httpRecorded)
            assertSame(owner.networkDiagnostics,owner.transferDiagnostics)
        } finally {owner.closeAndDrain()}
    }

    @Test fun `complete malformed response and capped partial response have different certainty`()=fixture {server,http->
        val owner=AccountWorkScheduler();val client=AccountClient(server.url("/").toString(),http,owner)
        try {
            val credential=credentials();server.json("{bad");server.json("123456789")
            assertFails {client.request("/v2/malformed",credential)}
            assertFailsWith<ClientFailure.Protocol> {client.request("/v2/capped",credential,maximumBytes=4)}
            val samples=owner.networkDiagnostics.snapshot().http
            assertEquals(NetworkMetric.Failure.InvalidResponse,samples[0].failure)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,samples[0].certainty)
            assertEquals(4,samples[0].receivedBytes)
            assertEquals(NetworkMetric.Certainty.OutcomeUnknown,samples[1].certainty)
            assertTrue(samples[1].receivedBytes>=5);assertEquals(NetworkMetric.Failure.InvalidResponse,samples[1].failure)
        } finally {owner.closeAndDrain()}
    }

    @Test fun `raw failure status is response evidence not a manufactured business outcome`()=fixture {server,http->
        val owner=AccountWorkScheduler();val client=AccountClient(server.url("/").toString(),http,owner)
        try {
            server.json(status=503)
            assertEquals(503,client.request("/v2/unavailable",credentials()).status)
            val sample=owner.networkDiagnostics.snapshot().http.single()
            assertEquals(503,sample.statusCode);assertNull(sample.failure)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
        } finally {owner.closeAndDrain()}
    }

    @Test fun `body timeout retains headers and never claims complete response`()=fixture {server,http->
        val owner=AccountWorkScheduler()
        val client=AccountClient(server.url("/").toString(),http.newBuilder().readTimeout(150,TimeUnit.MILLISECONDS).build(),owner)
        try {
            server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{}").setBodyDelay(500,TimeUnit.MILLISECONDS))
            assertFailsWith<java.net.SocketTimeoutException> {client.request("/v2/slow",credentials())}
            val sample=owner.networkDiagnostics.snapshot().http.single()
            assertEquals(200,sample.statusCode);assertEquals(NetworkMetric.Failure.DeadlineExceeded,sample.failure)
            assertFalse(sample.cancelled);assertEquals(NetworkMetric.Certainty.OutcomeUnknown,sample.certainty)
        } finally {owner.closeAndDrain()}
    }

    @Test fun `cancelled queued admission is not transmission and deadline consumes same queue budget`()=runTest {
        val owner=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
        val held=owner.acquire(NetworkWorkContext("account"));val credential=credentials()
        val client=AccountClient("https://localhost/",scheduler=owner)
        try {
            val pending=launch {client.request("/v2/queued",credential)}
            while(owner.snapshot().waiting==0) yield()
            pending.cancelAndJoin()
            val cancelled=owner.networkDiagnostics.snapshot().http.single()
            assertTrue(cancelled.cancelled);assertEquals(NetworkMetric.Certainty.NotStarted,cancelled.certainty)
            assertEquals(0,cancelled.elapsedNanos);assertEquals(0,cancelled.transactionCount);assertNull(cancelled.statusCode)
            assertFailsWith<AccountRequestDeadlineExceeded> {client.request("/v2/deadline",credential)}
            val deadline=owner.networkDiagnostics.snapshot().http.last()
            assertEquals(NetworkMetric.Failure.DeadlineExceeded,deadline.failure)
            assertEquals(NetworkMetric.Certainty.NotStarted,deadline.certainty);assertFalse(deadline.cancelled)
        } finally {owner.release(held);owner.closeAndDrain()}
    }

    @Test fun `cancellation publishes only after physical callback drain before permit release`()=fixture {server,http->coroutineScope {
        val entered=CountDownLatch(1);val gate=CountDownLatch(1)
        val gated=http.newBuilder().addInterceptor {chain->
            val response=chain.proceed(chain.request());entered.countDown()
            if(!gate.await(8,TimeUnit.SECONDS)) {response.close();error("Test gate timed out")}
            response
        }.build()
        val owner=AccountWorkScheduler();val credential=credentials()
        val client=AccountClient(server.url("/").toString(),gated,owner);server.json()
        val request=launch {client.request("/v2/held",credential)}
        try {
            assertTrue(withContext(Dispatchers.IO) {entered.await(5,TimeUnit.SECONDS)})
            request.cancel();yield()
            assertEquals(0,owner.networkDiagnostics.snapshot().httpRecorded);assertEquals(1,owner.snapshot().active)
            gate.countDown();request.join()
            val sample=owner.networkDiagnostics.snapshot().http.single()
            assertTrue(sample.cancelled);assertEquals(0,owner.snapshot().active)
        } finally {gate.countDown();request.cancelAndJoin();owner.closeAndDrain()}
        assertTrue(owner.networkDiagnostics.snapshot().closed);assertTrue(owner.networkDiagnostics.snapshot().http.isEmpty())
    }}

    @Test fun `account selection wins standalone scope and authentication uses reserved metadata`()=fixture {server,http->
        val owner=AccountWorkScheduler();val foreign=AccountWorkScheduler();val standalone=NetworkDiagnostics()
        val client=AccountClient(server.url("/").toString(),http,owner)
        try {
            server.json();server.json()
            withContext(NetworkDiagnosticsScope(standalone)+NetworkWorkScope(foreign,NetworkWorkContext("sensitive",NetworkWorkPriority.Background,isRetry=true))) {
                client.request("/v2/account",credentials())
                client.post("/v2/auth",buildJsonObject {})
            }
            assertEquals(0,standalone.snapshot().recorded);assertEquals(0,foreign.networkDiagnostics.snapshot().recorded)
            val samples=owner.networkDiagnostics.snapshot().http
            assertEquals(NetworkWorkPriority.Interactive,samples[0].priority);assertFalse(samples[0].isRetry)
            assertEquals(NetworkMetric.Service.Authentication,samples[1].service);assertEquals(NetworkWorkPriority.Critical,samples[1].priority)
            server.json()
            withContext(NetworkDiagnosticsScope(standalone)) {AccountClient(server.url("/").toString(),http).request("/v2/standalone",credentials())}
            assertEquals(1,standalone.snapshot().httpRecorded)
        } finally {owner.closeAndDrain();foreign.closeAndDrain();standalone.close()}
    }

    @Test fun `aggregate windows are immutable bounded and close rejects late observations`()=runBlocking {
        val diagnostics=NetworkDiagnostics()
        val sample=NetworkMetric(NetworkMetric.Service.Account,1,2,3,200,null,false,NetworkWorkPriority.Interactive,false,NetworkMetric.Certainty.ResponseReceived)
        diagnostics.record(sample);val previous=diagnostics.snapshot()
        coroutineScope {repeat(4) {launch(Dispatchers.Default) {repeat(100) {diagnostics.record(sample)}}}}
        diagnostics.record(ResourceTransferMetric(ResourceTransferMetric.Mode.Download,200,0,4,2,false,false,false))
        assertEquals(402,diagnostics.snapshot().recorded);assertEquals(401,diagnostics.snapshot().httpRecorded)
        assertEquals(128,diagnostics.snapshot().http.size);assertEquals(1,previous.http.size)
        diagnostics.close();diagnostics.record(sample)
        assertEquals(402,diagnostics.snapshot().recorded);assertTrue(diagnostics.snapshot().http.isEmpty())
        assertTrue(diagnostics.snapshot().samples.isEmpty());assertEquals(1,previous.httpRecorded)
        assertFailsWith<IllegalArgumentException> {sample.copy(queuedNanos=-1)}
        assertFailsWith<IllegalArgumentException> {HTTPPhaseTiming(tlsNanos=-1)}
        Unit
    }

    @Test fun `listener wrapper forwards every callback exposed by pinned OkHttp`() {
        val base=EventListener::class.java.declaredMethods.filter {java.lang.reflect.Modifier.isPublic(it.modifiers) && !java.lang.reflect.Modifier.isStatic(it.modifiers)}
        base.forEach {assertNotNull(HTTPMetricsListener::class.java.getDeclaredMethod(it.name,*it.parameterTypes))}
    }
}
