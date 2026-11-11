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
import java.security.MessageDigest
import java.util.UUID

class DownloadNetworkStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    @Test fun preferencesSurviveReopenAndRemainIsolatedFromAnotherAccount()=runBlocking {
        val actor=UserId(id());val device=DeviceId(id());var store=SqliteClientStore(context,actor,device)
        try {
            assertEquals(ResourceDownloadNetworkPreferences(),store.downloadNetworkPreferences())
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,true));store.close()
            store=SqliteClientStore(context,actor,device)
            assertEquals(ResourceDownloadNetworkPreferences(false,true),store.downloadNetworkPreferences())
            val other=SqliteClientStore(context,UserId(id()),device)
            try {assertEquals(ResourceDownloadNetworkPreferences(),other.downloadNetworkPreferences())} finally {other.close()}
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences());assertEquals(ResourceDownloadNetworkPreferences(),store.downloadNetworkPreferences())
        } finally {store.close()}
    }
    private fun scenario(body:suspend (SqliteClientStore,MockWebServer,HandshakeCertificates,File)->Unit) {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(cert).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val directory=File(context.filesDir,"network-test-${id()}").apply {mkdirs()}
        val store=SqliteClientStore(context,UserId(id()),DeviceId(id()))
        MockWebServer().use {server->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            try {runBlocking {withTimeout(15000) {body(store,server,trust,File(directory,"original"))}}}
            finally {store.close();directory.deleteRecursively()}
        }
    }
    private suspend fun target(server:MockWebServer):MediaDownloadTarget {
        val checksum=MessageDigest.getInstance("SHA-256").digest("download".toByteArray()).joinToString("") {"%02x".format(it)}
        return MediaDownloadTargetClient(object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("Unexpected request")
            override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                put("version",1);put("mode","http_get");put("url",server.url("/original").toString());put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",8);put("checksum",buildJsonObject {put("algorithm","sha256");put("value",checksum)})
            })})
        }).resolve(id(),null,null)
    }
    @Test fun blockedNetworkNeverCreatesConnectionAndFreshAttemptReadsPersistedPolicy()=scenario {store,server,trust,file->
        var binds=0;var network:ResourceDownloadNetworkState?=ResourceDownloadNetworkState(true,true,false)
        val downloader=PolicyMediaFileDownloader(store::downloadNetworkPreferences) {_ ->network?.let {state->DownloadNetworkRoute(state) {builder->
            binds++;builder.sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
        }}}
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,false))
        assertTrue(runCatching {downloader.download(target(server),file)}.exceptionOrNull() is ResourceDownloadPolicyRestricted)
        assertEquals(0,binds);assertEquals(0,server.requestCount);assertFalse(file.exists())
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,false));network=ResourceDownloadNetworkState(true,true,true)
        assertTrue(runCatching {downloader.download(target(server),file)}.exceptionOrNull() is ResourceDownloadPolicyRestricted)
        assertEquals(0,binds)
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true));server.enqueue(MockResponse().setBody("download"))
        downloader.download(target(server),file);assertEquals("download",file.readText());assertEquals(1,binds);assertEquals(1,server.requestCount)
        network=null
        assertTrue(runCatching {downloader.download(target(server),File(file.parentFile,"other"))}.exceptionOrNull() is ResourceTransferFailure)
        assertEquals(1,binds);assertEquals(1,server.requestCount)
    }
    @Test fun automaticWriterCannotBorrowManualMeteredAllowanceOrIgnoreCategoryRevocation()=scenario {store,server,trust,file->
        var metered=true;var calls=0
        val downloader=PolicyMediaFileDownloader(store::downloadNetworkPreferences) {_ ->DownloadNetworkRoute(ResourceDownloadNetworkState(false,metered,false)) {builder->
            calls++;builder.sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
        }}
        val target=target(server)
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(RoomId(id())),id()),1,"test","text/plain",8,target.plan.checksum,ResourceState.Ready)
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true,ResourceAutomaticDownloadPolicy(kotlinx.collections.immutable.persistentSetOf(ResourceCategory.File))))
        withContext(AutomaticResourceDownload(descriptor)) {
            assertTrue(runCatching {downloader.download(target,file)}.exceptionOrNull() is ResourceDownloadPolicyRestricted);assertEquals(0,calls)
            metered=false;store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true))
            assertTrue(runCatching {downloader.download(target,file)}.exceptionOrNull() is ResourceDownloadPolicyRestricted);assertEquals(0,calls)
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true,ResourceAutomaticDownloadPolicy(kotlinx.collections.immutable.persistentSetOf(ResourceCategory.File))))
            server.enqueue(MockResponse().setBody("download"));downloader.download(target,file)
        }
        assertEquals(1,calls);assertEquals("download",file.readText())
    }
    @Test fun localHttpsStillWorksWithoutDependingOnExternalNetworkPolicy()=scenario {store,server,trust,file->
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,false))
        val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
            .proxy(java.net.Proxy(java.net.Proxy.Type.HTTP,java.net.InetSocketAddress("127.0.0.1",9)))
            .dns(object:Dns {override fun lookup(hostname:String):List<java.net.InetAddress> = error("Loopback must not use inherited DNS")}).build()
        try {
            server.enqueue(MockResponse().setBody("download"))
            PolicyMediaFileDownloader(context,store,http).download(target(server),file)
            assertEquals("download",file.readText());assertEquals(1,server.requestCount)
        } finally {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
    }
}
