package com.xmtx.im.platform

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.*

/** Opt-in non-loopback HTTPS through Android's actual default Network and its bound socket factory. */
class DownloadNetworkDeviceTests {
    @Test fun realDefaultNetworkDownloadsWithCellularDisabledUsingBoundSockets()=verify(false)
    @Test fun foregroundAutomaticQueueDownloadsOverRealUnmeteredNetwork()=verify(true)
    private fun verify(automatic:Boolean)=runBlocking {
        val args=InstrumentationRegistry.getArguments();val url=args.getString("networkDownloadURL")
        assumeTrue("Requires host HTTPS fixture reachable through emulator network",url!=null)
        require(java.net.URI(url).host=="10.0.2.2")
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val manager=context.getSystemService(ConnectivityManager::class.java)
        val network=requireNotNull(manager.activeNetwork);val caps=requireNotNull(manager.getNetworkCapabilities(network))
        assertTrue(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI));assertFalse(caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))
        val cert=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("networkDownloadCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",cert)}
        val trust=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val tls=SSLContext.getInstance("TLS").apply {init(null,trust.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(tls.socketFactory,trust.trustManagers.single() as X509TrustManager).build()
        fun id()=UUID.randomUUID().toString().uppercase()
        val store=SqliteClientStore(context,UserId(id()),DeviceId(id()))
        val file=File(context.filesDir,"bound-network-${id()}")
        try {
            val preferences=ResourceDownloadNetworkPreferences(false,false,ResourceAutomaticDownloadPolicy(if(automatic) persistentSetOf(ResourceCategory.File) else persistentSetOf()))
            store.setDownloadNetworkPreferences(preferences)
            val bytes="bound-network-download";val checksum=MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") {"%02x".format(it)}
            val targets=MediaDownloadTargetClient(object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("Unexpected request")
                override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                    put("version",1);put("mode","http_get");put("url",url);put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                    put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",bytes.length);put("checksum",buildJsonObject {put("algorithm","sha256");put("value",checksum)})
                })})
            })
            if(automatic) {
                assertTrue(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                val room=RoomId(id());val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"自动下载.txt","text/plain",bytes.length.toLong(),ResourceChecksum(checksum),ResourceState.Ready)
                val message=MessageId(id())
                store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(persistentListOf(RoomResourceItem(message,1,RoomResourcePosition(1,0,descriptor.key.media),1000,descriptor)),1,null))
                val uploads=object:ResourceUploadControl {
                    override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("No upload")
                    override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("No upload")
                    override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("No upload")
                    override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
                    override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
                }
                val downloader=PolicyMediaFileDownloader(context,store,http)
                val activity=AccountResourceActivity(context,store,uploads,targets=targets,download=downloader::download)
                val run=launch {activity.runForeground()}
                try {
                    withTimeout(15000) {while(store.resourceDownloads().none {it.work.phase==ResourceDownloadPhase.Completed}) delay(10)}
                    val work=store.resourceDownloads().single().work;assertTrue(work.automatic);assertEquals(1,work.attempts)
                    val reader=MessageOriginalFiles(targets,store,activity.files)
                    try {assertEquals(bytes,reader.withOriginal(descriptor.key) {_,original->original.readText()})} finally {reader.close()}
                } finally {run.cancelAndJoin();activity.close()}
            } else {
                PolicyMediaFileDownloader(context,store,http).download(targets.resolve(id(),null,null),file)
                assertEquals(bytes,file.readText())
            }
            assertEquals(network,manager.activeNetwork);assertEquals(preferences,store.downloadNetworkPreferences())
        } finally {file.delete();File(file.path+".range-part").delete();File(file.path+".range-journal").delete();store.close();http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
    }
}
