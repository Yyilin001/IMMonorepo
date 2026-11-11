package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.*
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

class ResourceBackgroundDelegationBackendTests {
    @Test fun providerDelegatesMultipartBytesRejectsUnsupportedWholeAndFencesCancelledGrants() {
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
        java.io.File(context.noBackupFilesDir,"system-upload-test-ca.pem").writeBytes(Base64.getDecoder().decode(requireNotNull(arguments.getString("e2eCA"))))
        val port = requireNotNull(arguments.getString("e2eTLSPort")).toInt()
        val aSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        val bSocket = RealtimeConnection("localhost", port, ssl.socketFactory)
        var aStore: SqliteClientStore? = null; var bStore: SqliteClientStore? = null
        var managed:ManagedResourceFiles?=null
        var activity:AccountResourceActivity?=null
        var delegatedMappings:PersistentList<ResourceBackgroundUploadMapping> = persistentListOf()
        val systemDriver=ResourceSystemUploadDriver(context,TestResourceUploadJobService::class.java)
        val files=mutableListOf<java.io.File>()
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
                    val client=ResourceUploadClient(api,a.userId)
                    val uploader=ResourcePlanUploader(trustedHttp)
                    suspend fun ready(initial:ResourceUploadSession):ResourceUploadSession=withTimeout(45000) {
                        var value=initial
                        while(value.resourceState!=ResourceState.Ready) {
                            check(value.state !in setOf(ResourceSessionState.Cancelled,ResourceSessionState.Expired,ResourceSessionState.Failed))
                            delay(100);value=client.status(value)
                        }
                        value
                    }
                    fun source(size:Int):java.io.File=java.io.File.createTempFile("delegation-",".bin",context.cacheDir).apply {
                        outputStream().use {output->var left=size;val block=ByteArray(65536) {it.toByte()};while(left>0) {val count=minOf(left,block.size);output.write(block,0,count);left-=count}}
                        files+=this
                    }
                    fun checksum(file:java.io.File):ResourceChecksum {
                        val digest=java.security.MessageDigest.getInstance("SHA-256")
                        file.inputStream().use {input->val block=ByteArray(65536);while(true) {val count=input.read(block);if(count<0) break;digest.update(block,0,count)}}
                        return ResourceChecksum(digest.digest().joinToString("") {"%02x".format(it)})
                    }
                    fun request(file:java.io.File,mode:ResourceTransferMode)=ResourceUploadRequest(id(),id(),ResourceUsage.Attachment(sourceRoom),"application/octet-stream",file.length(),checksum(file),kotlinx.collections.immutable.persistentListOf(mode),"后台委托.bin")
                    phase="local provider rejects unsupported whole delegation without replacing the upload identity"
                    val wholeFile=source(1024);val wholeRequest=request(wholeFile,ResourceTransferMode.Put)
                    val whole=client.create(wholeRequest)
                    assertTrue(client.capabilities().background)
                    val unsupported=runCatching {client.backgroundTargets(whole,wholeRequest)}.exceptionOrNull()
                    assertTrue(unsupported is ClientFailure.Http && unsupported.status==422)
                    // Explicit caller choice: an ordinary target for the same session, never a hidden fallback or new Create.
                    val wholeTarget=requireNotNull(client.target(whole,wholeRequest));assertNull(wholeTarget.backgroundUpload)
                    uploader.upload(wholeFile,wholeTarget)
                    val wholeDone=ready(client.finalize(client.status(whole)));assertEquals(ResourceState.Ready,wholeDone.resourceState)
                    assertTrue(aStore!!.pending().isEmpty());assertTrue(aStore!!.sendIntents().isEmpty())
                    phase="two exact multipart delegations and authoritative part receipts"
                    val partFile=source(8*1024*1024+1024);val partRequest=request(partFile,ResourceTransferMode.PartPut)
                    managed=ManagedResourceFiles(context,aStore!!)
                    val asset=managed!!.importFile(partFile,"后台委托.bin","application/octet-stream",partRequest.usage,16L*1024*1024)
                    val work=aStore!!.prepareResourceUpload(id(),asset.id,partRequest)
                    val create=aStore!!.claimResourceUpload(work.id,id(),System.currentTimeMillis())!!
                    val partSession=client.create(partRequest)
                    aStore!!.finishResourceUpload(create,partSession,ResourceUploadAction.Upload,System.currentTimeMillis())
                    val upload=aStore!!.claimResourceUpload(work.id,id(),System.currentTimeMillis())!!
                    val targets=client.backgroundTargets(partSession,partRequest,kotlinx.collections.immutable.persistentListOf(2,1))
                    assertEquals(listOf(1,2),targets.map {it.plan.part});assertEquals(2,targets.map {it.authorization.id}.toSet().size)
                    val mappings=aStore!!.installBackgroundUploads(upload,targets.map {ResourceBackgroundUploadRegistration(id(),id(),it)}.toPersistentList())
                    val systemSession=aStore!!.backgroundUploadSession()
                    delegatedMappings=mappings
                    for((index,mapping) in mappings.withIndex()) systemDriver.schedule(aStore!!,managed!!,mapping,targets[index])
                    for((index,target) in targets.withIndex()) {
                        target.requireValid(partSession,partRequest)
                        val m=mappings[index]
                        val command="cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(m.task)}"
                        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command).use {descriptor->
                            val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().readText();check(output.contains("Running job"))
                        }
                        val result=withTimeout(45000) {
                            var value:ResourceBackgroundUploadResult?=null
                            while(value==null) {value=systemDriver.completions(systemSession).firstOrNull {it.mapping==m.id};if(value==null) delay(25)}
                            value
                        }
                        assertTrue(result.status in 200..299);assertEquals(m.expectedBytes,result.sentBytes)
                        assertEquals(1,systemDriver.reconcile(aStore!!,managed!!))
                        assertFalse(aStore!!.completeBackgroundUpload(m,result))
                        if(index==0) {
                            assertNull(aStore!!.claimResourceUpload(work.id,id(),System.currentTimeMillis()))
                            managed!!.close();aStore!!.close();aStore=SqliteClientStore(context,a.userId,a.deviceId)
                            managed=ManagedResourceFiles(context,aStore!!)
                            assertEquals(systemSession,aStore!!.backgroundUploadSession())
                            systemDriver.restore(systemSession)
                            assertEquals(listOf(mappings.last()),aStore!!.activeBackgroundUploads())
                            assertTrue(aStore!!.retireResourceFiles(persistentSetOf()).isEmpty())
                            managed!!.withOriginal(upload=work.id) {assertEquals(partRequest.checksum,checksum(it))}
                        }
                    }
                    phase="journal reopens and reconciles authoritative receipts before publishing Ready"
                    val waiting=aStore!!.resourceUploads().single()
                    assertFalse(waiting.terminal);assertFalse(waiting.execution.backgroundPending)
                    assertEquals(ResourceUploadAction.Status,waiting.execution.next);assertTrue(waiting.session!!.parts.isEmpty())
                    val statusClaim=aStore!!.claimResourceUpload(work.id,id(),System.currentTimeMillis())!!
                    val confirmed=client.status(partSession);assertEquals(listOf(1,2),confirmed.parts.map {it.number})
                    assertEquals(partFile.length(),confirmed.parts.sumOf {it.byteCount})
                    aStore!!.finishResourceUpload(statusClaim,confirmed,ResourceUploadAction.Finalize,System.currentTimeMillis())
                    val finalizeClaim=aStore!!.claimResourceUpload(work.id,id(),System.currentTimeMillis())!!
                    val partDone=ready(client.finalize(confirmed));assertEquals(ResourceState.Ready,partDone.resourceState)
                    aStore!!.finishResourceUpload(finalizeClaim,partDone,ResourceUploadAction.Status,System.currentTimeMillis())
                    assertTrue(aStore!!.resourceUploads().single().terminal);assertTrue(aStore!!.activeBackgroundUploads().isEmpty())
                    assertEquals(0L,managed!!.storageSnapshot().temporaryReservedBytes)
                    phase="cancelled original upload fences an already-issued provider grant"
                    val cancelledRequest=request(wholeFile,ResourceTransferMode.PartPut);val cancelled=client.create(cancelledRequest)
                    val stale=client.backgroundTargets(cancelled,cancelledRequest).single();val cancelledStatus=client.cancel(cancelled)
                    assertEquals(ResourceSessionState.Cancelled,cancelledStatus.state)
                    assertTrue(runCatching {stale.requireValid(cancelledStatus,cancelledRequest)}.isFailure)
                    val rejected=runCatching {uploader.upload(wholeFile,stale.plan)}.exceptionOrNull()
                    assertTrue("Provider must reject a previously delegated cancelled object",rejected is ClientFailure.Http && rejected.status in 400..499)
                    assertEquals(ResourceSessionState.Cancelled,client.status(cancelledStatus).state)
                    assertTrue(aStore!!.pending().isEmpty());assertTrue(aStore!!.sendIntents().isEmpty())
                    phase="account runtime automatically delegates consecutive parts and finalizes the original upload"
                    managed!!.close();managed=null
                    val finalizedParts=CompletableDeferred<PersistentList<Int>>()
                    val observedControl=object:ResourceUploadControl by client,ResourceBackgroundUploadControl by client {
                        override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession {
                            val result=client.finalize(session)
                            finalizedParts.complete(session.parts.map {it.number}.toPersistentList())
                            return result
                        }
                    }
                    val runtime=AccountResourceActivity(context,aStore!!,observedControl,systemUploads=systemDriver);activity=runtime
                    val automaticRequest=partRequest.copy(operation=id(),media=id())
                    val automaticAsset=runtime.files.importFile(partFile,"后台委托.bin","application/octet-stream",automaticRequest.usage,16L*1024*1024)
                    val automaticWork=aStore!!.prepareResourceUpload(id(),automaticAsset.id,automaticRequest)
                    val forced=mutableSetOf<String>()
                    coroutineScope {
                        val running=async {runtime.runBackground(60_000)}
                        withTimeout(60_000) {
                            while(!running.isCompleted) {
                                for(mapping in aStore!!.activeBackgroundUploads()) {
                                    if(mapping.task !in forced && context.getSystemService(android.app.job.JobScheduler::class.java).getPendingJob(systemUploadJobId(mapping.task))!=null) {
                                        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cmd jobscheduler run -f ${context.packageName} ${systemUploadJobId(mapping.task)}").use {descriptor->
                                            val output=android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().readText();check(output.contains("Running job"))
                                        }
                                        forced+=mapping.task
                                    }
                                }
                                delay(25)
                            }
                            assertEquals(ResourceBackgroundRunResult.Completed,running.await())
                        }
                    }
                    val automaticDone=aStore!!.resourceUploads().first {it.id==automaticWork.id}
                    assertEquals(2,forced.size);assertEquals(automaticRequest,automaticDone.request);assertEquals(ResourceUploadStage.Ready,automaticDone.stage)
                    // The provider may retire part receipts in its terminal response. Verify the
                    // authoritative receipts actually supplied to finalize, before that cleanup.
                    assertEquals(listOf(1,2),finalizedParts.await())
                    assertTrue(aStore!!.activeBackgroundUploads().isEmpty());assertEquals(0L,runtime.files.storageSnapshot().temporaryReservedBytes)
                    assertTrue(aStore!!.pending().isEmpty());assertTrue(aStore!!.sendIntents().isEmpty())
                    runtime.close();activity=null
                }
            } catch(error:Throwable) {throw AssertionError("Background delegation backend phase: $phase",error)}
            finally {withContext(NonCancellable) {activity?.close();delegatedMappings.forEach {systemDriver.cancelAndDrain(it)};if(aStore!=null && managed!=null) systemDriver.reconcile(aStore!!,managed!!)};managed?.close();files.forEach {it.delete()};aSocket.close();bSocket.close();aStore?.close();bStore?.close();trustedHttp.connectionPool.evictAll();trustedHttp.dispatcher.executorService.shutdown()}
        }
    }
}
