package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

class ResourceBackgroundDownloaderTests {
    private fun https(body:suspend (MockWebServer,OkHttpClient)->Unit) {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build();val keys=HandshakeCertificates.Builder().heldCertificate(cert).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        try {MockWebServer().use {server->server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start();runBlocking {withTimeout(15000) {body(server,http)}}}}
        finally {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
    }
    private fun plan(server:MockWebServer):ResourceTransferPlan {
        val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest("abcdefgh".toByteArray()).joinToString("") {"%02x".format(it)})
        val grant=ResourceBackgroundDownloadAuthorization(UUID.randomUUID().toString().uppercase(),8,checksum,1000,61000)
        return ResourceTransferPlan(ResourceTransferMode.Get,server.url("/original?cap=private").toString(),persistentListOf(),persistentMapOf(),null,61000,8,null,null,checksum,grant)
    }
    @Test fun progressStartsAfterValidHeadersCountsOnlySuccessfulWritesAndEndsOnFailure()=https {server,http->
        val expected=java.util.concurrent.CopyOnWriteArrayList<Long>();val bytes=java.util.concurrent.CopyOnWriteArrayList<Long>();val ended=java.util.concurrent.atomic.AtomicInteger()
        val observation=ResourceTransferProgressScope {size->expected.add(size);object:ResourceTransferByteObserver {
            override fun report(value:Long) {bytes.add(value)}
            override fun end() {ended.incrementAndGet()}
        }}
        server.enqueue(MockResponse().setBody("abcdefg"))
        assertTrue(runCatching {withContext(observation) {ResourceBackgroundDownloader(http,{1000}).download(plan(server),ByteArrayOutputStream())}}.isFailure)
        assertTrue(expected.isEmpty());assertEquals(0,ended.get())
        server.enqueue(MockResponse().setBody("abcdefgh"))
        val sink=object:java.io.OutputStream() {override fun write(b:Int) {throw java.io.IOException("unwritable test sink")}}
        assertTrue(runCatching {withContext(observation) {ResourceBackgroundDownloader(http,{1000}).download(plan(server),sink)}}.exceptionOrNull() is ResourceSourceUnavailable)
        assertEquals(listOf(8L),expected.toList());assertTrue(bytes.isEmpty());assertEquals(1,ended.get())
        server.enqueue(MockResponse().setBody("xxxxxxxx"))
        assertTrue(runCatching {withContext(observation) {ResourceBackgroundDownloader(http,{1000}).download(plan(server),ByteArrayOutputStream())}}.exceptionOrNull() is MediaReadFailure)
        assertEquals(8L,bytes.last());assertEquals(2,ended.get())
    }
    @Test fun verifiedWholeGetDropsInheritedCredentialsAndNeverAddsRange()=https {server,http->
        server.enqueue(MockResponse().setChunkedBody("abcdefgh",2));val output=ByteArrayOutputStream();var intercepted=false
        val tainted=http.newBuilder().addInterceptor {intercepted=true;it.proceed(it.request().newBuilder().header("Authorization","private").build())}.build()
        val target=plan(server);val result=ResourceBackgroundDownloader(tainted,{1000}).download(target,output)
        assertEquals(ResourceDownloadReceipt(200,8,resourceBackgroundOriginDigest(target.url)),result);assertEquals("abcdefgh",output.toString());assertFalse(intercepted)
        val request=server.takeRequest();assertNull(request.getHeader("Authorization"));assertNull(request.getHeader("Cookie"));assertNull(request.getHeader("Range"));assertEquals("identity",request.getHeader("Accept-Encoding"))
    }
    @Test fun redirectsRangeEncodingSizeAndHashFailuresCannotProduceReceipt()=https {server,http->
        val responses=listOf(MockResponse().setResponseCode(302).setHeader("Location",server.url("/other")),MockResponse().setResponseCode(206).setBody("abcdefgh"),
            MockResponse().setHeader("Content-Encoding","gzip").setBody("abcdefgh"),MockResponse().setBody("abcdefg"),MockResponse().setChunkedBody("abcdefghi",3),MockResponse().setBody("xxxxxxxx"))
        for(response in responses) {server.enqueue(response);assertTrue(runCatching {ResourceBackgroundDownloader(http,{1000}).download(plan(server),ByteArrayOutputStream())}.isFailure)}
        assertEquals(responses.size,server.requestCount)
    }
    @Test fun cancellationDrainsCallbackAndSinkReceivesNoLateWrites()=https {server,http->
        server.enqueue(MockResponse().setBody("abcdefgh").throttleBody(1,1,TimeUnit.SECONDS))
        val hub=ResourceTransferWaiting();val id=ResourceTransferId(ResourceTransferKind.Download,UUID.randomUUID().toString().uppercase())
        val output=ByteArrayOutputStream();val job=CoroutineScope(currentCoroutineContext()).launch(ResourceTransferProgressScope {hub.beginAttempt(id,it)}) {ResourceBackgroundDownloader(http,{1000}).download(plan(server),output)}
        withTimeout(5000) {while(output.size()==0) delay(10)};job.cancelAndJoin();val count=output.size();delay(100)
        assertEquals(count,output.size());assertTrue(count<8);assertTrue(hub.snapshots.value.attempts.isEmpty());hub.close()
    }
    @Test fun expiredOrOrdinaryTargetsNeverStartAndRetryAfterSurvivesHttpFailure()=https {server,http->
        val target=plan(server)
        assertTrue(runCatching {ResourceBackgroundDownloader(http,{61000}).download(target,ByteArrayOutputStream())}.isFailure)
        assertTrue(runCatching {ResourceBackgroundDownloader(http,{1000}).download(target.copy(backgroundDownload=null),ByteArrayOutputStream())}.isFailure)
        assertEquals(0,server.requestCount)
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After","60"))
        val error=runCatching {ResourceBackgroundDownloader(http,{1000}).download(target,ByteArrayOutputStream())}.exceptionOrNull() as ClientFailure.Http
        assertEquals(429,error.status);assertEquals("60",error.retryAfter)
    }
}
