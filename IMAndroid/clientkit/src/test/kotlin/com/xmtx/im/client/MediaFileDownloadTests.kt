package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.test.*

class MediaFileDownloadTests {
    private fun https(body: suspend (MockWebServer,OkHttpClient,File)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val directory=Files.createTempDirectory("range-download").toFile()
        MockWebServer().use { server ->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).dns(object: Dns { override fun lookup(hostname: String)=listOf(java.net.InetAddress.getByName("127.0.0.1")) }).build()
            try { runBlocking { withTimeout(15000) { body(server,http,File(directory,"original")) } } }
            finally { http.dispatcher.executorService.shutdown();http.connectionPool.evictAll();directory.deleteRecursively() }
        }
    }
    private fun target(server: MockWebServer,bytes: String="abcdefgh",deadline: Long=System.nanoTime()+60000000000): MediaDownloadTarget {
        val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") { "%02x".format(it) })
        val plan=ResourceTransferPlan(ResourceTransferMode.Get,server.url("/original?signature=private-secret").toString(),persistentListOf(ResourceTransferHeader("Authorization","Object capability",ResourceHeaderKind.ObjectCapability),ResourceTransferHeader("Accept-Encoding","gzip",ResourceHeaderKind.Content)),persistentMapOf(),null,System.currentTimeMillis()+60000,bytes.length.toLong(),null,null,checksum)
        return MediaDownloadTarget(plan,null,deadline,System::nanoTime)
    }
    private fun range(start: Int,end: Int,total: Int,body: String,etag: String="\"v1\"")=MockResponse().setResponseCode(206).setHeader("Content-Range","bytes $start-$end/$total").setHeader("ETag",etag).setBody(body)
    private fun journal(file: File)=File(file.path+".range-journal")
    private fun partial(file: File)=File(file.path+".range-part")
    @Test fun `only published matching strong validator rebuilds prove repeated prefix bytes`()=https {server,http,file->
        val diagnostics=ResourceTransferDiagnostics();val scope=ResourceTransferDiagnosticsScope(diagnostics)
        for(variant in 0..3) {
            server.enqueue(range(0,3,8,"abcd"))
            val response=MockResponse().setBody(if(variant==3) "xxxxxxxx" else "abcdefgh")
            if(variant!=2) response.setHeader("ETag",if(variant==1) "\"v2\"" else "\"v1\"")
            server.enqueue(response)
            withContext(scope) {
                if(variant==3) assertFailsWith<MediaFileFailure> {MediaFileDownloader(http,4).download(target(server),file)}
                else MediaFileDownloader(http,4).download(target(server),file)
            }
            val samples=diagnostics.snapshot().samples.takeLast(2)
            assertEquals(ResourceTransferMetric.Response.PartialResponse,samples[0].response);assertEquals(4,samples[0].bodyBytesReceived)
            assertEquals(ResourceTransferMetric.Response.FullResponseForRange,samples[1].response);assertEquals(8,samples[1].bodyBytesReceived)
            assertEquals(if(variant==0) 4L else null,samples[1].verifiedRangeRebuildPrefixBytes)
            assertNull(samples[0].verifiedRangeRebuildPrefixBytes);assertFalse(samples[1].cancelled)
            assertFalse(samples.toString().contains("private-secret"));file.delete();partial(file).delete();journal(file).delete()
        }
        assertEquals(8,diagnostics.snapshot().recorded)
    }
    @Test fun `range attempts report only accepted response bytes and end independently`()=https {server,http,file->coroutineScope {
        val id=ResourceTransferId(ResourceTransferKind.Download,java.util.UUID.randomUUID().toString().uppercase());val hub=ResourceTransferWaiting()
        server.enqueue(range(0,3,8,"abcd").throttleBody(1,150,TimeUnit.MILLISECONDS))
        server.enqueue(range(4,7,8,"efgh").throttleBody(1,150,TimeUnit.MILLISECONDS))
        val task=async(ResourceTransferWaitScope(id,hub)) {MediaFileDownloader(http,4).download(target(server),file)}
        try {
            val first=withTimeout(5000) {hub.snapshots.first {it.attempts[id]?.transferredBytes in 1L..3L}}.attempts[id]!!
            assertEquals(4,first.expectedBytes)
            val second=withTimeout(5000) {hub.snapshots.first {it.attempts[id]?.let {p->p.attemptId!=first.attemptId && p.transferredBytes in 1..3}==true}}.attempts[id]!!
            assertEquals(4,second.expectedBytes);task.await();assertEquals("abcdefgh",file.readText());assertTrue(hub.snapshots.value.attempts.isEmpty())
            assertEquals(2,server.requestCount)
        } finally {task.cancelAndJoin();hub.close()}
    }}
    @Test fun `full response fallback reports full body and cancellation removes attempt`()=https {server,http,file->coroutineScope {
        val id=ResourceTransferId(ResourceTransferKind.Download,java.util.UUID.randomUUID().toString().uppercase());val hub=ResourceTransferWaiting()
        server.enqueue(MockResponse().setBody("abcdefgh").throttleBody(1,300,TimeUnit.MILLISECONDS))
        val diagnostics=ResourceTransferDiagnostics()
        val task=launch(ResourceTransferWaitScope(id,hub)+ResourceTransferDiagnosticsScope(diagnostics)) {MediaFileDownloader(http,4).download(target(server),file)}
        try {
            val progress=withTimeout(5000) {hub.snapshots.first {it.attempts[id]?.transferredBytes in 1L..7L}}.attempts[id]!!
            assertEquals(8,progress.expectedBytes);task.cancelAndJoin();assertTrue(hub.snapshots.value.attempts.isEmpty());assertFalse(file.exists())
            assertTrue(partial(file).length() in 1..7)
            val sample=diagnostics.snapshot().samples.single();assertTrue(sample.cancelled);assertTrue(sample.failed);assertTrue(sample.bodyBytesReceived in 1..7);assertNull(sample.verifiedRangeRebuildPrefixBytes)
        } finally {task.cancelAndJoin();hub.close()}
    }}
    @Test fun `chunked original streams with isolated credentials and publishes only verified bytes`()=https { server,http,file ->
        var listener=0
        val tainted=http.newBuilder().addInterceptor { it.proceed(it.request().newBuilder().header("Authorization","Bearer private").header("X-IM-Device-ID","device").build()) }.eventListener(object: EventListener() { override fun callStart(call: Call) { listener++ } }).build()
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(range(4,7,8,"efgh"))
        MediaFileDownloader(tainted,4).download(target(server),file)
        assertEquals("abcdefgh",file.readText());assertFalse(partial(file).exists());assertFalse(journal(file).exists())
        repeat(2) { index -> val request=server.takeRequest();assertEquals("bytes=${index*4}-${index*4+3}",request.getHeader("Range"));assertEquals(if(index==0) null else "\"v1\"",request.getHeader("If-Range"));assertEquals("Object capability",request.getHeader("Authorization"));assertNull(request.getHeader("X-IM-Device-ID"));assertEquals("identity",request.getHeader("Accept-Encoding"));assertEquals("no-store",request.getHeader("Cache-Control")) }
        assertEquals(0,listener)
    }
    @Test fun `restart validates prefix and reuses only byte journal with fresh authorization`()=https { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setResponseCode(503))
        assertFailsWith<ClientFailure.Http> { MediaFileDownloader(http,4).download(target(server),file) }
        assertFalse(file.exists());assertEquals("abcd",partial(file).readText())
        val saved=journal(file).readText();listOf("private-secret","https","Authorization","capability").forEach { assertFalse(saved.contains(it)) }
        server.takeRequest();server.takeRequest();server.enqueue(range(4,7,8,"efgh"))
        MediaFileDownloader(http,4).download(target(server),file)
        val resumed=server.takeRequest();assertEquals("bytes=4-7",resumed.getHeader("Range"));assertEquals("\"v1\"",resumed.getHeader("If-Range"));assertEquals("abcdefgh",file.readText())
    }
    @Test fun `untrusted prefix corruption resets and trailing uncheckpointed bytes are truncated`()=https { server,http,file ->
        val t=target(server)
        MediaRangeFile(file.toPath(),t) {}.use { state ->
            val request=Request.Builder().url(t.plan.url).build()
            val response=Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(206).message("").header("Content-Range","bytes 0-3/8").header("ETag","\"v1\"").body("abcd".toResponseBody()).build()
            state.accept(response,0,3);state.append("abcd".toByteArray(),4);state.finishResponse()
        }
        partial(file).appendText("uncommitted")
        MediaRangeFile(file.toPath(),t) {}.use { assertEquals(4,it.offset);assertEquals("abcd",partial(file).readText()) }
        partial(file).writeText("xxxx")
        server.enqueue(range(0,7,8,"abcdefgh"));MediaFileDownloader(http,8).download(target(server),file)
        assertEquals("bytes=0-7",server.takeRequest().getHeader("Range"));assertEquals("abcdefgh",file.readText())
    }
    @Test fun `changed ETag discards prefix while 200 fallback rebuilds complete object`()=https { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(range(4,7,8,"efgh","\"v2\""))
        assertEquals(MediaFileFailureReason.VersionChanged,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http,4).download(target(server),file) }.reason)
        assertEquals(0,partial(file).length());assertFalse(file.exists())
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setBody("abcdefgh").setHeader("ETag","\"v2\""))
        MediaFileDownloader(http,4).download(target(server),file);assertEquals("abcdefgh",file.readText())
    }
    @Test fun `complete crash checkpoint is revalidated by 416 before publication`()=https { server,http,file ->
        val t=target(server)
        MediaRangeFile(file.toPath(),t) {}.use { state ->
            val response=Response.Builder().request(Request.Builder().url(t.plan.url).build()).protocol(Protocol.HTTP_1_1).code(200).message("").body("abcdefgh".toResponseBody()).build()
            state.accept(response,0,7);state.append("abcdefgh".toByteArray(),8);state.finishResponse()
        }
        server.enqueue(MockResponse().setResponseCode(416).setHeader("Content-Range","bytes */8").setBody("range completed"))
        val diagnostics=ResourceTransferDiagnostics()
        withContext(ResourceTransferDiagnosticsScope(diagnostics)) {MediaFileDownloader(http,4).download(target(server),file)}
        val sample=diagnostics.snapshot().samples.single();assertEquals(ResourceTransferMetric.Response.RangeUnsatisfied,sample.response);assertEquals(15,sample.bodyBytesReceived)
        assertEquals("bytes=8-11",server.takeRequest().getHeader("Range"));assertEquals("abcdefgh",file.readText())
    }
    @Test fun `malformed ranges coding length hashes and redirects never publish`()=https { server,http,file ->
        val bad=listOf(range(1,4,8,"abcd"),range(0,3,9,"abcd"),range(0,4,8,"abcde"),range(0,3,8,"abc"),range(0,3,8,"abcd").setHeader("Content-Encoding","gzip"),MockResponse().setBody("xxxxxxxx"),MockResponse().setResponseCode(302).setHeader("Location",server.url("/redirect")))
        for(response in bad) {
            server.enqueue(response);assertFails { MediaFileDownloader(http,4).download(target(server),file) };assertFalse(file.exists());partial(file).delete();journal(file).delete()
        }
        assertEquals(bad.size,server.requestCount)
    }
    @Test fun `zero length original and destination no overwrite are supported`()=https { server,http,file ->
        server.enqueue(MockResponse().setBody(""));MediaFileDownloader(http).download(target(server,""),file)
        assertTrue(file.exists());assertEquals(0,file.length())
        assertEquals(MediaFileFailureReason.DestinationExists,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http).download(target(server),file) }.reason);assertEquals(1,server.requestCount)
        file.delete()
        val foreign=File(file.parentFile,"foreign")
        Files.createSymbolicLink(file.toPath(),foreign.toPath())
        assertEquals(MediaFileFailureReason.DestinationExists,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http).download(target(server),file) }.reason)
        assertFalse(foreign.exists());file.delete()
        Files.createSymbolicLink(partial(file).toPath(),foreign.toPath())
        assertEquals(MediaFileFailureReason.InvalidJournal,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http).download(target(server),file) }.reason);assertEquals(1,server.requestCount)
    }
    @Test fun `cancel drains network preserves checkpoint and rejects same destination concurrently`()=https { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        coroutineScope {
            val task=launch { MediaFileDownloader(http,4).download(target(server),file) }
            repeat(2) { assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) }) }
            assertEquals(MediaFileFailureReason.DestinationExists,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http).download(target(server),file) }.reason)
            withTimeout(5000) { task.cancelAndJoin() }
        }
        assertFalse(file.exists());assertEquals(4,Json.parseToJsonElement(journal(file).readText()).jsonObject.getValue("offset").jsonPrimitive.long)
        server.enqueue(range(4,7,8,"efgh"));MediaFileDownloader(http,4).download(target(server),file);assertEquals("abcdefgh",file.readText())
    }
    @Test fun `publication rejects a racing destination and oversize error bodies stay bounded`()=https { server,http,file ->
        val t=target(server)
        MediaRangeFile(file.toPath(),t) {}.use { state ->
            val response=Response.Builder().request(Request.Builder().url(t.plan.url).build()).protocol(Protocol.HTTP_1_1).code(200).message("").body("abcdefgh".toResponseBody()).build()
            state.accept(response,0,7);state.append("abcdefgh".toByteArray(),8);state.finishResponse()
            file.writeText("other writer")
            assertEquals(MediaFileFailureReason.DestinationExists,assertFailsWith<MediaFileFailure> { state.publish() }.reason)
            assertEquals("other writer",file.readText())
        }
        file.delete()
        server.enqueue(MockResponse().setResponseCode(416).setHeader("Content-Range","bytes */8").setChunkedBody("x".repeat(65537),4096))
        assertEquals(MediaFileFailureReason.Integrity,assertFailsWith<MediaFileFailure> { MediaFileDownloader(http).download(target(server),file) }.reason)
        assertFalse(file.exists())
    }
    @Test fun `partial chunk failure saves only received bytes and resumes the exact offset`()=https { server,http,file ->
        server.enqueue(range(0,7,8,"abcdefgh").setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY))
        assertFails { MediaFileDownloader(http,8).download(target(server),file) }
        val saved=Json.parseToJsonElement(journal(file).readText()).jsonObject.getValue("offset").jsonPrimitive.long
        assertTrue(saved in 1..7);assertFalse(file.exists());server.takeRequest()
        server.enqueue(range(saved.toInt(),7,8,"abcdefgh".substring(saved.toInt())))
        MediaFileDownloader(http,8).download(target(server),file)
        assertEquals("bytes=$saved-7",server.takeRequest().getHeader("Range"));assertEquals("abcdefgh",file.readText())
    }
    @Test fun `expired targets and TLS failures preserve redacted errors`()=https { server,http,file ->
        assertEquals(MediaReadFailureReason.Expired,assertFailsWith<MediaReadFailure> { MediaFileDownloader(http).download(target(server,deadline=System.nanoTime()-1),file) }.reason)
        assertEquals(0,server.requestCount)
        val error=assertFailsWith<ResourceTransferFailure> { MediaFileDownloader().download(target(server),file) }
        generateSequence<Throwable>(error) { it.cause }.forEach { assertIs<ResourceTransferFailure>(it);assertFalse(it.toString().contains("private-secret")) };assertFalse(file.exists())
    }
}
