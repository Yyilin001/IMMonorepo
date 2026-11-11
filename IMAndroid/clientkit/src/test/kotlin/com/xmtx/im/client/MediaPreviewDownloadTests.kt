package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.util.concurrent.TimeUnit
import kotlin.test.*

class MediaPreviewDownloadTests {
    private fun https(body: suspend (MockWebServer,OkHttpClient)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try { runBlocking { body(server,http) } } finally { http.dispatcher.executorService.shutdown();http.connectionPool.evictAll() }
        }
    }
    @Test fun `real HTTPS authorization binds all query fields and object GET drops business credentials`()=https { server,http ->
        val f=MessagePreviewFixture();val auth=AuthSession(MemorySecrets(),FakeAccount()) { 0 };val credentials=auth.login("account","password123456")
        val api=AuthenticatedApi(auth,AccountClient(server.url("/").toString(),http),credentials.userId,credentials.deviceId)
        val target=f.target(server.url("/preview?signature=object-secret").toString())
        val body=buildJsonObject { put("plan",buildJsonObject {
            put("version",1);put("mode","http_get");put("url",target.plan.url);put("headers",buildJsonArray { add(buildJsonObject { put("name","Authorization");put("value","Object capability");put("kind","object_capability") });add(buildJsonObject { put("name","Accept-Encoding");put("value","gzip");put("kind","content") }) });put("formFields",buildJsonObject {});put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",f.bytes.size());put("checksum",f.checksum.payload())
        });put("preview",target.preview!!.payload()) }
        server.enqueue(MockResponse().setHeader("Content-Type","application/json").setBody(body.toString()))
        val resolved=MediaDownloadTargetClient(api).resolve(f.media,MediaMessageLocation(f.room,f.evidence.source.message),MediaImagePreviewSize.Thumbnail)
        val edge=server.takeRequest();assertEquals("GET",edge.method);assertEquals("no-store",edge.getHeader("Cache-Control"));assertEquals("Bearer sensitive-access",edge.getHeader("Authorization"));assertEquals(credentials.deviceId.value,edge.getHeader("X-IM-Device-ID"))
        assertEquals(f.room.value,edge.requestUrl!!.queryParameter("room_id"));assertEquals(f.evidence.source.message.value,edge.requestUrl!!.queryParameter("message_id"));assertEquals("320",edge.requestUrl!!.queryParameter("image_size"))
        var events=0
        val tainted=http.newBuilder().addInterceptor { it.proceed(it.request().newBuilder().header("Authorization","Bearer business-secret").header("X-IM-Device-ID","device").build()) }.eventListener(object: EventListener() { override fun callStart(call: Call) { events++ } }).build()
        server.enqueue(MockResponse().setBody(okio.Buffer().write(f.bytes.toByteArray())))
        assertEquals(f.bytes,MediaPreviewDownloader(tainted).download(resolved))
        val objectRequest=server.takeRequest();assertEquals("Object capability",objectRequest.getHeader("Authorization"));assertNull(objectRequest.getHeader("X-IM-Device-ID"));assertNull(objectRequest.getHeader("Cookie"));assertEquals("identity",objectRequest.getHeader("Accept-Encoding"));assertEquals("no-store",objectRequest.getHeader("Cache-Control"));assertEquals(0,events)
    }
    @Test fun `length digest coding partial responses and redirect mismatches cannot publish pixels`()=https { server,http ->
        val f=MessagePreviewFixture();val downloader=MediaPreviewDownloader(http);val target=f.target(server.url("/preview").toString())
        for(response in listOf(MockResponse().setBody("short"),MockResponse().setChunkedBody(f.bytes.toStringUtf8()+"more",4),MockResponse().setBody("x".repeat(f.bytes.size())),MockResponse().setBody(f.bytes.toStringUtf8()).setHeader("Content-Encoding","gzip"),MockResponse().setBody(f.bytes.toStringUtf8()).setHeader("Content-Range","bytes 0-21/22"))) {
            server.enqueue(response);assertEquals(MediaReadFailureReason.Integrity,assertFailsWith<MediaReadFailure> { downloader.download(target) }.reason)
        }
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location",server.url("/redirect")))
        assertEquals(302,assertFailsWith<ClientFailure.Http> { downloader.download(target) }.status);assertEquals(6,server.requestCount)
    }
    @Test fun `expired queued targets cancellation and TLS errors remain bounded and redacted`()=https { server,http ->
        val f=MessagePreviewFixture();val downloader=MediaPreviewDownloader(http)
        assertEquals(MediaReadFailureReason.Expired,assertFailsWith<MediaReadFailure> { downloader.download(f.target(server.url("/preview").toString(),deadline=System.nanoTime()-1)) }.reason)
        assertEquals(0,server.requestCount)
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        coroutineScope {
            val job=launch { downloader.download(f.target(server.url("/preview").toString())) }
            assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) });withTimeout(5000) { job.cancelAndJoin() }
        }
        val error=assertFailsWith<ResourceTransferFailure> { MediaPreviewDownloader().download(f.target(server.url("/preview?signature=private-object-secret").toString())) }
        generateSequence<Throwable>(error) { it.cause }.forEach { assertIs<ResourceTransferFailure>(it);assertFalse(it.toString().contains("signature"));assertFalse(it.toString().contains("capability")) }
    }
}
