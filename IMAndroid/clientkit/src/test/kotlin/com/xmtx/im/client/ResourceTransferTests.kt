package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ResourceTransferTests {
    private fun https(block: (MockWebServer,OkHttpClient) -> Unit) {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverKeys = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.protocols = listOf(Protocol.HTTP_1_1)
            server.useHttps(serverKeys.sslSocketFactory(),false);server.start()
            val client = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try { block(server,client) } finally { client.dispatcher.executorService.shutdown();client.connectionPool.evictAll() }
        }
    }
    private fun source(block: (File) -> Unit) {
        val file = File.createTempFile("resource-test-",".bin")
        try { file.writeText("字节内容\n");block(file) } finally { file.delete() }
    }
    private fun checksum(file: File) = ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) })
    private fun plan(server: MockWebServer,file: File) = ResourceTransferPlan(ResourceTransferMode.Put,server.url("/object?signature=private-object-token").toString(),
        persistentListOf(ResourceTransferHeader("Content-Type","application/octet-stream",ResourceHeaderKind.Content),ResourceTransferHeader("Authorization","Object private-capability",ResourceHeaderKind.ObjectCapability)),
        persistentMapOf(),null,System.currentTimeMillis()+60000,file.length(),null,null,checksum(file))
    @Test fun `whole and part upload progress stays observational until response and drains on cancellation`() {
        val id=ResourceTransferId(ResourceTransferKind.Upload,java.util.UUID.randomUUID().toString().uppercase());val hub=ResourceTransferWaiting()
        var previous:String?=null
        for(part in listOf(false,true)) {https {server,http->source {file->runBlocking {
            val request=plan(server,file).let {if(part) it.copy(mode=ResourceTransferMode.PartPut,range=ResourceRange(100,99+file.length()),part=2) else it}
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val task=async(ResourceTransferWaitScope(id,hub)) {ResourcePlanUploader(http).uploadReceipt(file,request)}
            try {
                val observed=withTimeout(5000) {hub.snapshots.first {it.attempts[id]?.transferredBytes==file.length()}}.attempts[id]!!
                assertEquals(file.length(),observed.expectedBytes);assertNotEquals(previous,observed.attemptId);previous=observed.attemptId
                val wire=withContext(Dispatchers.IO) {server.takeRequest(5,TimeUnit.SECONDS)}!!
                assertContentEquals(file.readBytes(),wire.body.readByteArray());assertFalse(task.isCompleted)
                task.cancelAndJoin();assertTrue(hub.snapshots.value.attempts.isEmpty())
            } finally {task.cancelAndJoin()}
        }}}}
        hub.close()
    }

    @Test fun `whole and part metrics count body streams and distinguish retry from duplicate bytes`()=https {server,http->source {file->runBlocking {
        val scheduler=AccountWorkScheduler();val scope=NetworkWorkScope(scheduler,NetworkWorkContext("account"))
        try {
            server.enqueue(MockResponse().setResponseCode(204))
            withContext(scope) {ResourcePlanUploader(http).upload(file,plan(server,file))}
            server.enqueue(MockResponse().setResponseCode(503).setBody("provider body"))
            withContext(scope+NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {
                assertFailsWith<ClientFailure.Http> {ResourcePlanUploader(http).upload(file,plan(server,file).copy(mode=ResourceTransferMode.PartPut,range=ResourceRange(0,file.length()-1),part=1))}
            }
            val samples=scheduler.transferDiagnostics.snapshot().samples;assertEquals(2,samples.size)
            assertEquals(ResourceTransferMetric.Mode.Upload,samples[0].mode);assertFalse(samples[0].retryAttempt);assertEquals(0,samples[0].bodyBytesReceived)
            assertEquals(ResourceTransferMetric.Mode.MultipartUpload,samples[1].mode);assertTrue(samples[1].retryAttempt)
            assertEquals(13,samples[1].bodyBytesReceived);assertEquals(503,samples[1].statusCode);assertFalse(samples[1].failed)
            samples.forEach {assertEquals(file.length(),it.bodyBytesSent);assertFalse(it.cancelled);assertNull(it.verifiedRangeRebuildPrefixBytes)}
            assertFalse(samples.toString().contains("private"));assertFalse(samples.toString().contains("provider body"))
            assertFailsWith<IllegalArgumentException> {withContext(scope) {ResourcePlanUploader(http).upload(file,plan(server,file).copy(expectedBytes=file.length()+1))}}
            assertEquals(2,scheduler.transferDiagnostics.snapshot().recorded)
        } finally {scheduler.closeAndDrain()}
    }}}
    @Test fun `uploads exact bytes and discards application interceptors cookies and credentials`() = https { server,http -> source { file -> runBlocking {
        var businessEvents=0
        val tainted = http.newBuilder().eventListener(object: EventListener() { override fun callStart(call: Call) { businessEvents++ } })
            .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("X-IM-Device-ID","business-device").header("Authorization","Bearer business-secret").build()) }
            .addNetworkInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("X-Business-Secret","secret").build()) }
            .cookieJar(object: CookieJar {
                override fun saveFromResponse(url: HttpUrl,cookies: List<Cookie>) = Unit
                override fun loadForRequest(url: HttpUrl) = listOf(Cookie.Builder().name("business-cookie").value("secret").domain("localhost").build())
            }).build()
        server.enqueue(MockResponse().setResponseCode(204))
        val receipt=ResourcePlanUploader(tainted).uploadReceipt(file,plan(server,file))
        assertEquals(204,receipt.status);assertEquals(file.length(),receipt.sentBytes);assertEquals(resourceBackgroundOriginDigest(server.url("/").toString()),receipt.originDigest)
        val request = server.takeRequest();assertEquals("PUT",request.method);assertContentEquals(file.readBytes(),request.body.readByteArray())
        assertEquals(file.length().toString(),request.getHeader("Content-Length"));assertEquals("application/octet-stream",request.getHeader("Content-Type"))
        assertEquals("Object private-capability",request.getHeader("Authorization"));assertNull(request.getHeader("X-IM-Device-ID"));assertNull(request.getHeader("X-Business-Secret"));assertNull(request.getHeader("Cookie"))
        assertEquals(0,businessEvents)
    } } }
    @Test fun `delegated upload treats issue time as provider metadata and retains exact source checks`() = https {server,http->source {file->runBlocking {
        val instant=System.currentTimeMillis()
        val original=plan(server,file)
        val grant=ResourceBackgroundUploadAuthorization("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",1,"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            ResourceBackgroundUploadScope.Whole(file.length(),checksum(file)),instant+1,original.expiresAt)
        val delegated=original.copy(headers=original.headers.filter {it.kind==ResourceHeaderKind.Content}.toPersistentList(),backgroundUpload=grant)
        val uploader=ResourcePlanUploader(http) {instant}
        server.enqueue(MockResponse().setResponseCode(204))
        uploader.upload(file,delegated)
        val received=server.takeRequest();assertContentEquals(file.readBytes(),received.body.readByteArray());assertNull(received.getHeader("Authorization"));assertNull(received.getHeader("Cookie"))
    }}}
    @Test fun `part upload consumes an already bounded slice and sends no range header`() = https { server,http -> source { file -> runBlocking {
        val part = plan(server,file).copy(mode=ResourceTransferMode.PartPut,range=ResourceRange(100,99+file.length()),part=2)
        server.enqueue(MockResponse().setBody("provider receipt discarded"));ResourcePlanUploader(http).upload(file,part)
        val request = server.takeRequest();assertContentEquals(file.readBytes(),request.body.readByteArray());assertNull(request.getHeader("Range"));assertEquals(1,server.requestCount)
    } } }
    @Test fun `length checksum expiry and download direction fail before sending bytes`() = https { server,http -> source { file -> runBlocking {
        val valid = plan(server,file);val uploader = ResourcePlanUploader(http)
        for(invalid in listOf(valid.copy(expectedBytes=file.length()+1),valid.copy(checksum=ResourceChecksum("0".repeat(64))),valid.copy(expiresAt=0),valid.copy(mode=ResourceTransferMode.Get))) {
            assertFailsWith<IllegalArgumentException> { uploader.upload(file,invalid) }
        }
        assertEquals(0,server.requestCount)
    } } }
    @Test fun `redirects are not followed and provider errors never expose response body`() = https { server,http -> source { file -> runBlocking {
        val uploader = ResourcePlanUploader(http)
        server.enqueue(MockResponse().setResponseCode(307).setHeader("Location",server.url("/stolen")).setBody("private provider error"))
        val redirect = assertFailsWith<ClientFailure.Http> { uploader.upload(file,plan(server,file)) };assertEquals(307,redirect.status);assertFalse(redirect.toString().contains("private"))
        server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After","17").setBody("private provider error"))
        val retry = assertFailsWith<ClientFailure.Http> { uploader.upload(file,plan(server,file)) };assertEquals(503,retry.status);assertEquals("17",retry.retryAfter)
        assertEquals(2,server.requestCount)
    } } }
    @Test fun `response ceiling applies to both declared and chunked bodies`() = https { server,http -> source { file -> runBlocking {
        val uploader = ResourcePlanUploader(http)
        server.enqueue(MockResponse().setBody("a".repeat(524289)))
        assertFailsWith<ClientFailure.Protocol> { uploader.upload(file,plan(server,file)) }
        server.enqueue(MockResponse().setChunkedBody("a".repeat(524289),8192))
        assertFailsWith<ClientFailure.Protocol> { uploader.upload(file,plan(server,file)) }
        server.enqueue(MockResponse().setChunkedBody("a".repeat(524288),8192));uploader.upload(file,plan(server,file))
    } } }
    @Test fun `cancellation drains the physical call before source cleanup`() = https { server,http -> source { file -> runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val diagnostics=ResourceTransferDiagnostics()
        val operation = launch(ResourceTransferDiagnosticsScope(diagnostics)) { ResourcePlanUploader(http).upload(file,plan(server,file)) }
        assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) })
        withTimeout(5000) { operation.cancelAndJoin() }
        val sample=diagnostics.snapshot().samples.single();assertTrue(sample.cancelled);assertTrue(sample.failed);assertEquals(file.length(),sample.bodyBytesSent)
        assertTrue(file.delete());assertEquals(1,server.requestCount)
    } } }
    @Test fun `failed TLS hides provider url and capability`() = https { server,_ -> source { file -> runBlocking {
        val failure = assertFailsWith<ResourceTransferFailure> { ResourcePlanUploader().upload(file,plan(server,file)) }
        generateSequence<Throwable>(failure) { it.cause }.forEach { assertIs<ResourceTransferFailure>(it);assertFalse(it.toString().contains("signature")) }
    } } }
    @Test fun `array transport opts in bounds response and preserves account device binding`() = https { server,http -> runBlocking {
        val transport = AccountClient(server.url("/").toString(),http)
        val auth = AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials = auth.login("account","password123456")
        val api = AuthenticatedApi(auth,transport,credentials.userId,credentials.deviceId)
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("[]"))
        assertNotNull(api.requestArray("/v2/resource-uploads/targets",buildJsonObject {}).arrayBody)
        val request = server.takeRequest();assertEquals("POST",request.method);assertEquals("Bearer ${credentials.accessToken}",request.getHeader("Authorization"));assertEquals(credentials.deviceId.value,request.getHeader("X-IM-Device-ID"))
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("[]"))
        assertFailsWith<ClientFailure.Protocol> { transport.request("/v2/test",credentials) }
        server.enqueue(MockResponse().setChunkedBody("[\""+"a".repeat(524288)+"\"]",8192).setHeader("Content-Type","application/json"))
        assertFailsWith<ClientFailure.Protocol> { api.requestArray("/v2/resource-uploads/targets",buildJsonObject {}) }
        val wrong = AuthenticatedApi(auth,transport,UserId("another-account"),credentials.deviceId)
        assertFailsWith<ClientFailure.SignedOut> { wrong.requestArray("/v2/resource-uploads/targets",buildJsonObject {}) };assertEquals(3,server.requestCount)
    } }
    @Test fun `array plans reject business bearer even with percent encoded text and malformed percent elsewhere`() = https { server,http -> runBlocking {
        val auth = AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials = auth.login("account","password123456")
        val api = AuthenticatedApi(auth,AccountClient(server.url("/").toString(),http),credentials.userId,credentials.deviceId)
        val encoded = credentials.accessToken.toByteArray().joinToString("") { "%%%02X".format(it) }
        for(secret in listOf(credentials.accessToken,encoded,"bad%escape $encoded")) {
            val body = buildJsonArray { add(buildJsonObject { put("headers",buildJsonArray { add(buildJsonObject { put("value",secret) }) }) }) }
            server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(body.toString()))
            assertFailsWith<ClientFailure.Protocol> { api.requestArray("/v2/resource-uploads/targets",buildJsonObject {}) }
        }
    } }
    @Test fun `object presentation plans reject raw and encoded business credentials before leaving auth boundary`() = https { server,http -> runBlocking {
        val auth=AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials=auth.login("account","password123456")
        val api=AuthenticatedApi(auth,AccountClient(server.url("/").toString(),http),credentials.userId,credentials.deviceId)
        val encoded=credentials.accessToken.toByteArray().joinToString("") { "%%%02X".format(it) }
        for(secret in listOf(credentials.accessToken,encoded,"bad%escape $encoded")) {
            val body=buildJsonObject { put("avatar",buildJsonObject { put("plan",buildJsonObject { put("url","https://delivery.invalid/?token=$secret") }) }) }
            server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(body.toString()))
            assertFailsWith<ClientFailure.Protocol> { api.requestWithResourcePlans("/v2/rooms/avatar") }
        }
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody("{}"))
        assertTrue(api.requestWithResourcePlans("/v2/rooms/avatar").body.isEmpty())
        val wrong=AuthenticatedApi(auth,AccountClient(server.url("/").toString(),http),UserId("another-account"),credentials.deviceId)
        assertFailsWith<ClientFailure.SignedOut> { wrong.requestWithResourcePlans("/v2/rooms/avatar") };assertEquals(4,server.requestCount)
    } }
}
