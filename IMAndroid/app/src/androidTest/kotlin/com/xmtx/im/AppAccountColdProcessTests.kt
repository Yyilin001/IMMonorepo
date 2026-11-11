package com.xmtx.im

import android.app.Application
import android.app.job.JobScheduler
import android.net.ConnectivityManager
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.net.URI
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.*

/** Explicit two-process backend test; the host observes death before starting the production JobService. */
@OptIn(ExperimentalTestApi::class,ExperimentalCoroutinesApi::class)
class AppAccountColdProcessTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>(effectContext=kotlinx.coroutines.test.StandardTestDispatcher())
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private class Fixture(val run:String,val endpoint:String,val port:Int,val http:OkHttpClient,val ssl:SSLContext,
        val creates:AtomicInteger,val statuses:AtomicInteger,val finalizes:AtomicInteger,val transfers:AtomicInteger,val transferBytes:AtomicLong) {
        val preferences="cold-$run-endpoint";val credentials="cold-$run-credentials"
        fun bytes(files:ManagedResourceFiles):ResourceUploadBytes {
            val actual=ManagedResourceUploadBytes(files,ResourcePlanUploader(http))
            return object:ResourceUploadBytes by actual {
                override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                    actual.transfer(owner,work,plan)
                    transfers.incrementAndGet();transferBytes.addAndGet(plan.expectedBytes)
                }
            }
        }
        fun close() {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
    }
    private fun fixture():Fixture {
        val args=InstrumentationRegistry.getArguments()
        assumeTrue("Requires explicit cold-account backend orchestration",args.getString("coldAccount")=="true")
        val run=requireNotNull(args.getString("coldRun"));require(run.matches(Regex("[0-9a-f]{12}")))
        val endpoint=requireNotNull(args.getString("e2eURL"));val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("fixture",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val creates=AtomicInteger();val statuses=AtomicInteger();val finalizes=AtomicInteger()
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager)
            .addInterceptor {chain->
                val request=chain.request()
                when(request.url.encodedPath) {
                    "/v2/resource-uploads"->creates.incrementAndGet()
                    "/v2/resource-uploads/status"->statuses.incrementAndGet()
                    "/v2/resource-uploads/finalize"->finalizes.incrementAndGet()
                }
                chain.proceed(request)
            }.build()
        return Fixture(run,endpoint,port,http,ssl,creates,statuses,finalizes,AtomicInteger(),AtomicLong())
    }
    private fun metadata(f:Fixture)=File(context.noBackupFilesDir,"account-cold-${f.run}.json")

    @Test fun prepareRealAccountDelegationForProcessDeath()=runBlocking<Unit> {
        val f=fixture();val metadata=metadata(f)
        check(!metadata.exists()) {"Cold fixture already exists; inspect/recover it before starting another preparation"}
        assertNull(context.getSystemService(ConnectivityManager::class.java).activeNetwork)
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        var activity:AccountResourceActivity?=null;var store:SqliteClientStore?=null;var published=false
        val source=File.createTempFile("cold-account-",".bin",context.cacheDir)
        try {
            withTimeout(90_000) {
                val transport=AccountClient(f.endpoint,f.http)
                val auth=AuthSession(KeystoreSecretStore(context,f.credentials),transport)
                val peer=AuthSession(KeystoreSecretStore(context,"cold-${f.run}-peer"),transport)
                val password=id()+"aA1!"
                val actor=auth.login("cold_${f.run}_a",password,true,"cold_${f.run}_a","冷启动 A")
                val other=peer.login("cold_${f.run}_b",password,true,"cold_${f.run}_b","冷启动 B")
                check(context.getSharedPreferences(f.preferences,0).edit().putString("url",f.endpoint).commit())
                val db=openBoundFixtureStore(context,actor.userId,actor.deviceId);store=db
                val api=AuthenticatedApi(auth,transport,actor.userId,actor.deviceId)
                val directs=DirectRoomService(actor.userId,DirectRoomClient(api),db)
                val direct=directs.prepare(other.userId)
                var room:RoomId?=null
                while(room==null) {directs.flush();room=db.directWorks().first {it.command.operation==direct.command.operation}.room;if(room==null) delay(250)}
                peer.logout()
                val client=ResourceUploadClient(api,actor.userId)
                val resources=AccountResourceActivity(context,db,client,bytes=f::bytes);activity=resources
                source.outputStream().use {out->val block=ByteArray(65536) {it.toByte()};repeat(128) {out.write(block)};out.write(block,0,1024)}
                val asset=resources.files.importFile(source,"冷启动附件.bin","application/octet-stream",ResourceUsage.Attachment(room),16L*1024*1024)
                val request=ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,persistentListOf(ResourceTransferMode.PartPut),asset.displayName)
                val work=db.prepareResourceUpload(id(),asset.id,request)
                val running=scope.async {resources.runBackground()}
                var selected:Pair<ResourceBackgroundUploadMapping,Int>?=null
                while(selected==null) {
                    if(running.isCompleted) error("Background runtime ended before delegation: ${running.await()}")
                    val mapping=db.activeBackgroundUploads().singleOrNull()
                    val job=mapping?.let {value->context.getSystemService(JobScheduler::class.java).allPendingJobs.singleOrNull {it.extras.getString("task")==value.task}}
                    if(mapping!=null && job!=null) selected=mapping to job.id else delay(10)
                }
                val (mapping,job)=selected
                assertEquals(1,f.creates.get());assertEquals(0,f.transfers.get())
                assertTrue(db.resourceUploads().single().execution.backgroundPending)
                assertTrue(resources.files.storageSnapshot().temporaryReservedBytes>0)
                val value=buildJsonObject {
                    put("run",f.run);put("actor",actor.userId.value);put("device",actor.deviceId.value);put("upload",work.id)
                    put("requestDigest",resourceBackgroundRequestDigest(request));put("mapping",mapping.payload())
                    put("pid",android.os.Process.myPid());put("job",job);put("byteCount",source.length())
                }
                metadata.writeText(value.toString())
                published=true
                // Keep the real account lease alive. The host kills this exact process after
                // instrumentation exits; a graceful close would intentionally drain the job.
            }
        } finally {
            source.delete()
            if(!published) {scope.cancel();activity?.close();store?.close();f.close()}
        }
    }

    @Test fun coldAppRestoresCredentialsReconcilesUnknownSystemResultAndFinalizesOriginalUpload() {
        val f=fixture();val metadata=metadata(f)
        val value=Json.parseToJsonElement(metadata.readText()).jsonObject
        val actor=UserId(value.getValue("actor").jsonPrimitive.content);val device=DeviceId(value.getValue("device").jsonPrimitive.content)
        val upload=value.getValue("upload").jsonPrimitive.content;val digest=value.getValue("requestDigest").jsonPrimitive.content
        val mapping=ResourceBackgroundUploadMapping.decode(value.getValue("mapping").jsonObject)
        assertNotEquals(value.getValue("pid").jsonPrimitive.int,android.os.Process.myPid())
        val driver=ResourceSystemUploadDriver(context)
        runBlocking {
            val credentials=AuthSession(KeystoreSecretStore(context,f.credentials),AccountClient(f.endpoint,f.http)).current()!!
            assertEquals(actor,credentials.userId);assertEquals(device,credentials.deviceId)
            // The production JobService had no scheduler-provided network. Its unknown receipt
            // must survive the original process and must not masquerade as successful bytes.
            val receipt=driver.completions(mapping.systemSession).single()
            assertEquals(mapping.id,receipt.mapping);assertNull(receipt.status);assertNotNull(receipt.error);assertEquals(0L,receipt.sentBytes)
            val db=openBoundFixtureStore(context,actor,device)
            try {assertEquals(listOf(mapping),db.activeBackgroundUploads());assertTrue(db.resourceUploads().single().execution.backgroundPending)} finally {db.close()}
        }
        val dependencies=AppDependencies(account={AccountClient(it,f.http)},realtime={RealtimeConnection(URI(it).host,f.port,f.ssl.socketFactory,authorPresentations=true)},
            preferencesName=f.preferences,credentialsName=f.credentials,download=MediaFileDownloader(f.http)::download,
            uploadBytes=f::bytes)
        var model:AppViewModel?=null;val models=ViewModelStore();var displayed by mutableStateOf<AppViewModel?>(null)
        try {
            compose.runOnUiThread {model=AppViewModel(context.applicationContext as Application,dependencies);models.put("cold-app",model!!);displayed=model}
            compose.setContent {displayed?.let {ApplicationContent(it)}}
            compose.waitUntil(60_000) {model!!.state.value.resourceUploads.any {it.id==upload && it.stage==ResourceUploadStage.Ready}}
            val state=model!!.state.value;val session=state.session as SessionUi.SignedIn
            assertEquals(actor,session.user);assertFalse(session.demo);assertNotNull(session.databaseIdentity)
            val work=state.resourceUploads.single {it.id==upload}
            assertEquals(digest,resourceBackgroundRequestDigest(work.request));assertEquals(mapping.authorization.session,work.session!!.locator.session)
            assertEquals(0,f.creates.get());assertTrue(f.statuses.get()>0);assertEquals(1,f.finalizes.get())
            assertEquals(2,f.transfers.get());assertEquals(value.getValue("byteCount").jsonPrimitive.long,f.transferBytes.get())
            compose.onNodeWithTag("conversation-list").assertExists()
            runBlocking {assertTrue(driver.completions(mapping.systemSession).isEmpty())}
        } finally {
            compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
            model?.let {owner->
                val waiting=CoroutineScope(SupervisorJob()+Dispatchers.Default)
                try {val closed=waiting.async {owner.awaitShutdown()};compose.waitUntil(15_000) {closed.isCompleted};runBlocking {closed.await()}}
                finally {waiting.cancel()}
            }
            f.close()
        }
        runBlocking {
            val db=openBoundFixtureStore(context,actor,device);val files=ManagedResourceFiles(context,db)
            try {
                val work=db.resourceUploads().single();assertEquals(upload,work.id);assertEquals(ResourceUploadStage.Ready,work.stage)
                assertEquals(digest,resourceBackgroundRequestDigest(work.request));assertTrue(db.activeBackgroundUploads().isEmpty())
                assertEquals(0L,files.storageSnapshot().temporaryReservedBytes)
                assertTrue(db.pending().isEmpty());assertTrue(db.sendIntents().isEmpty());assertFalse(work.sourceReleased)
                files.withOriginal(upload=upload) {assertEquals(value.getValue("byteCount").jsonPrimitive.long,it.length())}
            } finally {files.close();db.close()}
        }
        File(context.noBackupFilesDir,"account-cold-${f.run}-verified.json").writeText(buildJsonObject {
            put("run",f.run);put("preparedPid",value.getValue("pid"));put("appPid",android.os.Process.myPid())
            put("createCalls",f.creates.get());put("statusCalls",f.statuses.get());put("finalizeCalls",f.finalizes.get());put("completedTransfers",f.transfers.get());put("transferBytes",f.transferBytes.get())
            put("originalRequestPreserved",true);put("ready",true);put("temporaryReservedBytes",0)
        }.toString())
    }

    @Test fun cleanupColdAccountFixture()=runBlocking<Unit> {
        val f=fixture()
        try {
            val auth=AuthSession(KeystoreSecretStore(context,f.credentials),AccountClient(f.endpoint,f.http))
            auth.current()?.let {credentials->
                val path=metadata(f)
                if(path.exists()) {
                    val value=Json.parseToJsonElement(path.readText()).jsonObject
                    assertEquals(value.getValue("actor").jsonPrimitive.content,credentials.userId.value)
                    assertEquals(value.getValue("device").jsonPrimitive.content,credentials.deviceId.value)
                }
                val db=openBoundFixtureStore(context,credentials.userId,credentials.deviceId);val files=ManagedResourceFiles(context,db);val driver=ResourceSystemUploadDriver(context)
                try {
                    for(mapping in db.activeBackgroundUploads()) {
                        val result=driver.cancelAndDrain(mapping)
                        db.completeBackgroundUpload(mapping,result);files.releaseBackgroundUploadSource(mapping)
                    }
                    driver.reconcile(db,files)
                    assertTrue(db.activeBackgroundUploads().isEmpty());assertEquals(0L,files.storageSnapshot().temporaryReservedBytes)
                } finally {files.close();db.close()}
            }
            auth.logout()
            AuthSession(KeystoreSecretStore(context,"cold-${f.run}-peer"),AccountClient(f.endpoint,f.http)).logout()
        } finally {f.close()}
    }
}
