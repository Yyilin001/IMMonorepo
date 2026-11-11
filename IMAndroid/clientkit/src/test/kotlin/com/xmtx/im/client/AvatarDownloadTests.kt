package com.xmtx.im.client

import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.util.concurrent.TimeUnit
import kotlin.test.*

class AvatarDownloadTests {
    private fun https(body: suspend (MockWebServer,OkHttpClient)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        MockWebServer().use { server ->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try { runBlocking { body(server,http) } } finally { http.dispatcher.executorService.shutdown();http.connectionPool.evictAll() }
        }
    }
    @Test fun `download verifies immutable bytes drops business credentials and rechecks borrowing permission`()=https { server,http ->
        val f=AvatarFixture();val scope=f.scope(f.available(f.access(server.url("/avatar?signature=private-object-secret").toString())))
        val grant=scope.avatarReadGrant(f.key)!!;var events=0
        val tainted=http.newBuilder().addInterceptor { it.proceed(it.request().newBuilder().header("Authorization","Bearer business-secret").header("X-IM-Device-ID","device").build()) }
            .eventListener(object: EventListener() { override fun callStart(call: Call) { events++ } }).cookieJar(object: CookieJar {
                override fun saveFromResponse(url: HttpUrl,cookies: List<Cookie>)=Unit
                override fun loadForRequest(url: HttpUrl)=listOf(Cookie.Builder().name("session").value("private").domain("localhost").build())
            }).build()
        server.enqueue(MockResponse().setBody(okio.Buffer().write(f.bytes)))
        val downloaded=AvatarDownloader(tainted).download(grant);assertContentEquals(f.bytes,downloaded.read().toByteArray())
        val request=server.takeRequest();assertEquals("GET",request.method);assertEquals("Object private-capability",request.getHeader("Authorization"));assertEquals("identity",request.getHeader("Accept-Encoding"))
        assertNull(request.getHeader("Cookie"));assertNull(request.getHeader("X-IM-Device-ID"));assertEquals(0,events)
        scope.close();assertFailsWith<AvatarAccessFailure> { downloaded.read() };assertFalse(grant.toString().contains("private-object-secret"))
    }
    @Test fun `length digest coding partial responses and redirects cannot publish bytes`()=https { server,http ->
        val f=AvatarFixture();val scope=f.scope(f.available(f.access(server.url("/avatar").toString())));val downloader=AvatarDownloader(http)
        for(response in listOf(MockResponse().setBody("short"),MockResponse().setChunkedBody(String(f.bytes)+"more",4),
            MockResponse().setBody("x".repeat(f.bytes.size)),MockResponse().setBody(String(f.bytes)).setHeader("Content-Encoding","gzip"),
            MockResponse().setBody(String(f.bytes)).setHeader("Content-Range","bytes 0-20/21"))) {
            server.enqueue(response);assertFailsWith<AvatarIntegrityFailure> { downloader.download(scope.avatarReadGrant(f.key)!!) }
        }
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location",server.url("/redirect")))
        assertEquals(302,assertFailsWith<ClientFailure.Http> { downloader.download(scope.avatarReadGrant(f.key)!!) }.status);assertEquals(6,server.requestCount);scope.close()
    }
    @Test fun `revocation during download expiry and cancellation reject unpublished content`()=https { server,http ->
        val f=AvatarFixture();val scope=f.scope(f.available(f.access(server.url("/avatar").toString())));val downloader=AvatarDownloader(http)
        server.enqueue(MockResponse().setBody(String(f.bytes)).setBodyDelay(300,TimeUnit.MILLISECONDS))
        coroutineScope {
            val task=async { runCatching { downloader.download(scope.avatarReadGrant(f.key)!!) } }
            assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) });scope.invalidate(f.key)
            assertIs<AvatarAccessFailure>(task.await().exceptionOrNull())
        }
        scope.refresh();val expired=scope.avatarReadGrant(f.key)!!;f.clock=60_000_000_100
        assertFailsWith<AvatarTargetExpired> { downloader.download(expired) };assertEquals(1,server.requestCount);f.clock=100
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        coroutineScope {
            val task=launch { downloader.download(scope.avatarReadGrant(f.key)!!) }
            assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) });withTimeout(5000) { task.cancelAndJoin() }
        };scope.close()
    }
    @Test fun `untrusted TLS never leaks object capability or signed URL`()=https { server,_ ->
        val f=AvatarFixture();val scope=f.scope(f.available(f.access(server.url("/avatar?signature=private-object-secret").toString())))
        val error=assertFailsWith<ResourceTransferFailure> { AvatarDownloader().download(scope.avatarReadGrant(f.key)!!) }
        generateSequence<Throwable>(error) { it.cause }.forEach { assertIs<ResourceTransferFailure>(it);assertFalse(it.toString().contains("signature"));assertFalse(it.toString().contains("private-capability")) };scope.close()
    }
}
