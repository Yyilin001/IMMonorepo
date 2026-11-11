package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Exercise Android's SHA provider, fsync, atomic journal replacement and same-directory publication. */
class MediaFileDownloadStorageTests {
    private fun scenario(body: suspend (MockWebServer,OkHttpClient,File)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val directory=File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"download-test-${UUID.randomUUID()}").apply { mkdirs() }
        MockWebServer().use { server ->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).dns(object: Dns { override fun lookup(hostname: String)=listOf(java.net.InetAddress.getByName("127.0.0.1")) }).build()
            try { runBlocking { withTimeout(15000) { body(server,http,File(directory,"original")) } } }
            finally { http.dispatcher.executorService.shutdown();http.connectionPool.evictAll();directory.deleteRecursively() }
        }
    }
    private suspend fun target(server: MockWebServer,bytes: String="abcdefgh"): MediaDownloadTarget {
        val checksum=MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") { "%02x".format(it) }
        val api=object: AuthenticatedTransport {
            override suspend fun request(path: String,payload: JsonObject?,query: Pair<String,String>?,maximumBytes: Long): EdgeResponse=error("unexpected replayable request")
            override suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long)=EdgeResponse(200,buildJsonObject { put("plan",buildJsonObject {
                put("version",1);put("mode","http_get");put("url",server.url("/original?signature=private").toString());put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",bytes.length);put("checksum",buildJsonObject { put("algorithm","sha256");put("value",checksum) })
            }) })
        }
        return MediaDownloadTargetClient(api).resolve(UUID.randomUUID().toString().uppercase(),null,null)
    }
    private fun range(start: Int,end: Int,total: Int,bytes: String)=MockResponse().setResponseCode(206).setHeader("Content-Range","bytes $start-$end/$total").setHeader("ETag","\"v1\"").setBody(bytes)
    @Test fun recoverCheckpointAcrossDownloaderRecreationAndPublishWithoutOverwrite()=scenario { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setResponseCode(503))
        assertTrue(runCatching { MediaFileDownloader(http,4).download(target(server),file) }.exceptionOrNull() is ClientFailure.Http)
        assertFalse(file.exists());assertEquals("abcd",File(file.path+".range-part").readText());assertFalse(File(file.path+".range-journal").readText().contains("private"))
        repeat(2) { server.takeRequest() };server.enqueue(range(4,7,8,"efgh"))
        MediaFileDownloader(http,4).download(target(server),file)
        val resumed=server.takeRequest();assertEquals("bytes=4-7",resumed.getHeader("Range"));assertEquals("\"v1\"",resumed.getHeader("If-Range"));assertEquals("abcdefgh",file.readText())
        assertFalse(File(file.path+".range-part").exists());assertFalse(File(file.path+".range-journal").exists())
        val error=runCatching { MediaFileDownloader(http).download(target(server),file) }.exceptionOrNull()
        assertTrue(error is MediaFileFailure && error.reason==MediaFileFailureReason.DestinationExists);assertEquals("abcdefgh",file.readText());assertEquals(3,server.requestCount)
    }
    @Test fun corruptedPrefixResetsAndSymlinkJournalFailsClosed()=scenario { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setResponseCode(503))
        assertTrue(runCatching { MediaFileDownloader(http,4).download(target(server),file) }.isFailure)
        File(file.path+".range-part").writeText("xxxx");repeat(2) { server.takeRequest() }
        server.enqueue(range(0,7,8,"abcdefgh"));MediaFileDownloader(http,8).download(target(server),file)
        assertEquals("bytes=0-7",server.takeRequest().getHeader("Range"));assertEquals("abcdefgh",file.readText());file.delete()
        val foreign=File(file.parentFile,"foreign").apply { writeText("preserve") }
        Files.createSymbolicLink(File(file.path+".range-journal").toPath(),foreign.toPath())
        val error=runCatching { MediaFileDownloader(http).download(target(server),file) }.exceptionOrNull()
        assertTrue(error is MediaFileFailure && error.reason==MediaFileFailureReason.InvalidJournal);assertEquals("preserve",foreign.readText());assertEquals(3,server.requestCount)
    }
    @Test fun cancellationDrainsBeforeResumingSavedPrefix()=scenario { server,http,file ->
        server.enqueue(range(0,3,8,"abcd"));server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        coroutineScope {
            val task=launch { MediaFileDownloader(http,4).download(target(server),file) }
            repeat(2) { assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5,TimeUnit.SECONDS) }) };withTimeout(5000) { task.cancelAndJoin() }
        }
        assertFalse(file.exists());server.enqueue(range(4,7,8,"efgh"));MediaFileDownloader(http,4).download(target(server),file)
        assertEquals("bytes=4-7",server.takeRequest().getHeader("Range"));assertEquals("abcdefgh",file.readText())
    }
    @Test fun largeFallbackStreamsThroughMultipleCheckpointsAndVerifiesAndroidDigest()=scenario { server,http,file ->
        val bytes="z".repeat(2*1024*1024+19)
        server.enqueue(MockResponse().setBody(bytes));MediaFileDownloader(http).download(target(server,bytes),file)
        assertEquals(bytes.length.toLong(),file.length());assertEquals(bytes,file.readText());assertFalse(File(file.path+".range-journal").exists())
    }
}
