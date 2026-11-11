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

class ResourcePreparationCancellationBackendTests {
    @Test fun reviewedCancellationRecoversAnUnknownRealImportWithoutSendingItsParent() {
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
        val run = UUID.randomUUID().toString().replace("-", "").take(12)
        val aSecrets = KeystoreSecretStore(context, "e2e-$run-a"); val bSecrets = KeystoreSecretStore(context, "e2e-$run-b")
        val aAuth = AuthSession(aSecrets, transport); val bAuth = AuthSession(bSecrets, transport)
        val port = requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        val bSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        var aStore: SqliteClientStore? = null; var bStore: SqliteClientStore? = null
        var resources: AccountResourceActivity?=null
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
                    phase="upload and bind an authorized source message"
                    resources=AccountResourceActivity(context,aStore!!,ResourceUploadClient(api,a.userId)) {ManagedResourceUploadBytes(it,ResourcePlanUploader(trustedHttp))}
                    val bitmap=android.graphics.Bitmap.createBitmap(96,64,android.graphics.Bitmap.Config.ARGB_8888)
                    val bytes=com.google.protobuf.ByteString.newOutput()
                    try {bitmap.eraseColor(android.graphics.Color.CYAN);assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,bytes))} finally {bitmap.recycle()}
                    val photo=resources!!.files.importPhoto(PhotoPreparation().prepare(bytes.toByteString()),ResourceUsage.Attachment(sourceRoom))
                    val sending=SendIntentService(a.userId,aStore!!)
                    val sourceIntent=sending.enqueue(sourceRoom,"取消预览来源 $run",kotlinx.collections.immutable.persistentListOf(SendAttachment(photo.id,photo.id,photo.displayName,photo.contentType,photo.byteCount)))
                    coroutineScope {
                        val transfer=launch {resources!!.runForeground()};val prepare=launch {sending.runPreparation()}
                        try {withTimeout(45000) {while(aStore!!.pending().none {it.clientMessageId==sourceIntent.operation}) delay(100)}}
                        finally {prepare.cancelAndJoin();transfer.cancelAndJoin()}
                    }
                    MessageOutbox(aSocket,aStore!!).flush()
                    withTimeout(15000) {while(aStore!!.snapshot().messages.none {it.text==sourceIntent.text && it.revision>0}) {RoomSyncEngine(aSocket,aStore!!).synchronize();delay(100)}}
                    val message=aStore!!.snapshot().messages.single {it.text==sourceIntent.text && it.revision>0}
                    resources!!.close();resources=null
                    phase="prepare message import and lose its real create reply"
                    val imported=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(sourceRoom,message.id,photo.id),ResourceUsage.Attachment(sourceRoom),id()))
                    val cancelledText="取消准备不应发送 $run"
                    val parent=SendIntentService(a.userId,aStore!!).enqueue(SendIntentService(a.userId,aStore!!).prepare(sourceRoom,cancelledText,kotlinx.collections.immutable.persistentListOf(),serverImports=kotlinx.collections.immutable.persistentListOf(imported)))
                    val remote=ResourceImportClient(api,a.userId);var creates=0
                    val lossy=object:ResourceImportControl by remote {override suspend fun create(request:ResourceImportRequest):ResourceImportStatus {
                        creates++;remote.create(request);throw IOException("simulated lost preparation import reply")
                    }}
                    ResourceImportService(a.userId,aStore!!,lossy).recoverOnce()
                    assertEquals(1,creates);assertNull(aStore!!.resourceImports().single().status)
                    val transfer=ResourceTransferId(ResourceTransferKind.ServerImport,imported.id)
                    val plan=aStore!!.planResourcePreparationCancellation(transfer);assertEquals(1,plan.messageCount)
                    phase="server becomes Ready while reviewed local status is still unknown"
                    withTimeout(45000) {while(remote.status(imported.request.locator(a.userId)).state!=ResourceImportState.Ready) delay(100)}
                    assertEquals(ResourcePreparationCancellationResult(1,0,1),aStore!!.cancelResourcePreparation(plan))
                    assertTrue(aStore!!.pending().none {it.clientMessageId==parent.operation})
                    aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                    phase="restart confirms cancellation of original identity and never retries message creation"
                    var cancels=0
                    val recovery=object:ResourceImportControl by remote {
                        override suspend fun create(request:ResourceImportRequest):ResourceImportStatus=error("Cancelled import must not create another target")
                        override suspend fun cancel(locator:ResourceImportLocator):ResourceImportStatus {assertEquals(imported.request.locator(a.userId),locator);cancels++;return remote.cancel(locator)}
                    }
                    val imports=ResourceImportService(a.userId,aStore!!,recovery)
                    withTimeout(45000) {while(!aStore!!.resourceImports().single().cancellationResolved) {imports.recoverOnce();delay(100)}}
                    SendIntentService(a.userId,aStore!!).prepareNext()
                    val done=aStore!!.resourceImports().single();assertEquals(imported.request,done.request);assertEquals(ResourceImportState.Ready,done.status!!.state)
                    assertTrue(done.cancellationRequested);assertTrue(done.cancellationResolved);assertFalse(done.businessBound);assertFalse(done.bindable(System.currentTimeMillis()))
                    assertTrue(cancels>=1);assertEquals(1,creates)
                    val withdrawn=aStore!!.sendIntents().first {it.intent.id==parent.id};assertEquals(SendIntentPhase.Cancelled,withdrawn.phase);assertTrue(withdrawn.intent.sourcesReleased)
                    assertTrue(aStore!!.pending().none {it.clientMessageId==parent.operation})
                    MessageOutbox(aSocket,aStore!!).flush();backendSync {RoomSyncEngine(bSocket,bStore!!).synchronize()}
                    assertTrue(bStore!!.snapshot().messages.none {it.text==cancelledText})
                }
            } catch(error:Throwable) {throw AssertionError("Preparation cancellation backend phase: $phase",error)}
            finally {resources?.close();aSocket.close();bSocket.close();aStore?.close();bStore?.close();trustedHttp.connectionPool.evictAll();trustedHttp.dispatcher.executorService.shutdown()}
        }
    }
}
