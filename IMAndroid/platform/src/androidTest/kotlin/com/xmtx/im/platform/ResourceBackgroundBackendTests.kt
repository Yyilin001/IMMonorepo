package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class ResourceBackgroundBackendTests {
    @Test fun boundedBackgroundLeaseUploadsImportsAndDownloadsWithoutSubmittingBusinessCommands() {
        val arguments = InstrumentationRegistry.getArguments()
        val endpoint = arguments.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend instrumentation arguments", endpoint != null)
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))).inputStream())
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null); setCertificateEntry("test", certificate) }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trustStore) }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }
        val trustedHttp = OkHttpClient.Builder()
            .sslSocketFactory(ssl.socketFactory, managers.trustManagers.single() as X509TrustManager).build()
        val transport = AccountClient(endpoint!!, trustedHttp)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        java.io.File(context.noBackupFilesDir,"system-download-test-ca.pem").writeBytes(Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))))
        java.io.File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeBytes(Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))))
        val run = UUID.randomUUID().toString().replace("-", "").take(12)
        val aSecrets = KeystoreSecretStore(context, "e2e-$run-a"); val bSecrets = KeystoreSecretStore(context, "e2e-$run-b")
        val aAuth = AuthSession(aSecrets, transport); val bAuth = AuthSession(bSecrets, transport)
        val port = requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        val bSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        var aStore: SqliteClientStore? = null; var bStore: SqliteClientStore? = null
        var resources: AccountResourceActivity?=null;var receiver:AccountResourceActivity?=null
        var phase="authentication"
        runBlocking {
            try {
                withTimeout(180_000) {
                    val password = UUID.randomUUID().toString() + "aA1!"
                    val a = aAuth.login("device_${run}_a", password, true, "device_${run}_a", "设备 A")
                    val b = bAuth.login("device_${run}_b", password, true, "device_${run}_b", "设备 B")
                    phase="bootstrap persistence and messages"
                    val bootstrap = bootstrapBackend(context, a, b, aAuth, bAuth, transport, aSocket, bSocket, run, aSecrets)
                    aStore = bootstrap.first; bStore = bootstrap.second
                    fun id()=UUID.randomUUID().toString().uppercase()
                    val api=bootstrap.api;val peerApi=bootstrap.peerApi;val sourceRoom=bootstrap.room
                    phase="background upload without foreground preparation or command submission"
                    resources=AccountResourceActivity(context,aStore!!,ResourceUploadClient(api,a.userId),imports=ResourceImportClient(api,a.userId),
                        systemUploads=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)) {ManagedResourceUploadBytes(it,ResourcePlanUploader(trustedHttp))}
                    val bitmap=android.graphics.Bitmap.createBitmap(96,64,android.graphics.Bitmap.Config.ARGB_8888)
                    val bytes=com.google.protobuf.ByteString.newOutput()
                    try {bitmap.eraseColor(android.graphics.Color.CYAN);assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes))} finally {bitmap.recycle()}
                    val photo=resources!!.files.importPhoto(PhotoPreparation().prepare(bytes.toByteString()),ResourceUsage.Attachment(sourceRoom))
                    val sending=SendIntentService(a.userId,aStore!!)
                    val sourceIntent=sending.enqueue(sourceRoom,"后台资源来源 $run",kotlinx.collections.immutable.persistentListOf(SendAttachment(photo.id,photo.id,photo.displayName,photo.contentType,photo.byteCount)))
                    val uploading=async {resources!!.runBackground(45000)};val forcedUploads=mutableSetOf<String>()
                    // This offline fixture must explicitly run every delegated upload before testing its peer download.
                    while(!uploading.isCompleted) {
                        for(mapping in aStore!!.activeBackgroundUploads()) {
                            if(mapping.task in forcedUploads || context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task))==null) continue
                            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(mapping.task)}").use {fd->
                                val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).bufferedReader().readText();assertTrue(output,output.contains("Running job"))
                            }
                            forcedUploads.add(mapping.task)
                        }
                        delay(20)
                    }
                    assertEquals(ResourceBackgroundRunResult.Completed,uploading.await());assertTrue(forcedUploads.isNotEmpty())
                    assertEquals(ResourceUploadStage.Ready,aStore!!.resourceUploads().single().stage)
                    assertNull(aStore!!.resourceUploads().single().execution.owner)
                    assertTrue(aStore!!.pending().isEmpty())
                    assertEquals(SendPreparation.Preparing,aStore!!.sendIntents().single().intent.preparation)
                    phase="explicit foreground business preparation binds the uploaded resource"
                    sending.prepareNext();assertTrue(aStore!!.pending().any {it.clientMessageId==sourceIntent.operation})
                    MessageOutbox(aSocket,aStore!!).flush()
                    withTimeout(15000) {while(aStore!!.snapshot().messages.none {it.text==sourceIntent.text && it.revision>0}) {RoomSyncEngine(aSocket,aStore!!).synchronize();delay(100)}}
                    val message=aStore!!.snapshot().messages.single {it.text==sourceIntent.text && it.revision>0}
                    phase="background server import uses the authorized original message"
                    val request=ResourceImportRequest(id(),ResourceImportSource.Message(sourceRoom,message.id,photo.id),ResourceUsage.UserAvatar,id())
                    val imported=aStore!!.prepareResourceImport(id(),request,System.currentTimeMillis())
                    assertEquals(ResourceBackgroundRunResult.Completed,resources!!.runBackground(45000))
                    val ready=aStore!!.resourceImports().single {it.id==imported.id}
                    assertEquals(ResourceImportState.Ready,ready.status!!.state);assertNull(ready.execution.owner);assertFalse(ready.businessBound)
                    assertTrue(aStore!!.profileIntents().isEmpty())
                    phase="peer background download resolves fresh authorization and verified bytes"
                    backendSync {RoomSyncEngine(bSocket,bStore!!).synchronize()}
                    ResourceDirectorySynchronizer(bStore!!,RoomResourceDirectoryClient(peerApi)).refresh(sourceRoom)
                    val key=ResourceKey(ResourceHome.Room(sourceRoom),photo.id)
                    val download=bStore!!.enqueueResourceDownload(key,bStore!!.resourceSources(key).sources.single())
                    var downloads=0
                    val downloader=MediaFileDownloader(trustedHttp)
                    val systemDriver=ResourceSystemDownloadDriver(context,TestResourceDownloadJobService::class.java)
                    val resolver=MediaDownloadTargetClient(peerApi);var resolutions=0
                    receiver=AccountResourceActivity(context,bStore!!,ResourceUploadClient(peerApi,b.userId),download={target,file->downloads++;downloader.download(target,file)},
                        targets={media,message,size->resolutions++;resolver.resolve(media,message,size)},systemDownloads=systemDriver)
                    val background=async {receiver!!.runBackground(45000)}
                    var mapping:ResourceBackgroundDownloadMapping?=null
                    withTimeout(15000) {while(mapping==null) {
                        if(background.isCompleted) {
                            val work=bStore!!.resourceDownloads().single {it.work.id==download.id}.work
                            error("Download ended before system admission: phase=${work.phase}, issue=${work.issue}, attempts=${work.attempts}, fallback=$downloads, resolutions=$resolutions")
                        }
                        mapping=bStore!!.activeBackgroundDownloads().singleOrNull()?.mapping?.takeIf {context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemDownloadJobId(it.task))!=null}
                        if(mapping==null) delay(20)
                    }}
                    ResourceSystemDownloadTests().force(requireNotNull(mapping).task)
                    assertEquals(ResourceBackgroundRunResult.Completed,background.await())
                    val done=bStore!!.resourceDownloads().single {it.work.id==download.id}.work
                    assertEquals(ResourceDownloadPhase.Completed,done.phase);assertNull(done.owner);assertEquals(0,downloads);assertEquals(2,resolutions)
                    assertTrue(bStore!!.activeBackgroundDownloads().isEmpty());assertTrue(systemDriver.completions(requireNotNull(mapping).systemSession).isEmpty())
                    assertEquals(0L,receiver!!.files.storageSnapshot().temporaryReservedBytes)
                    assertTrue(receiver!!.files.resourceVariants(key).single {it.descriptor.key.rendition==ResourceRendition.Original}.availableLocally)
                    receiver!!.close();receiver=null;bStore!!.close();bStore=SqliteClientStore(context,b.userId,b.deviceId)
                    assertEquals(ResourceDownloadPhase.Completed,bStore!!.resourceDownloads().single {it.work.id==download.id}.work.phase)
                    assertTrue(bStore!!.pending().isEmpty())
                }
            } catch(error:Throwable) {throw AssertionError("Background resource backend phase: $phase",error)}
            finally {receiver?.close();resources?.close();aSocket.close();bSocket.close();aStore?.close();bStore?.close();trustedHttp.connectionPool.evictAll();trustedHttp.dispatcher.executorService.shutdown()}
        }
    }
}
