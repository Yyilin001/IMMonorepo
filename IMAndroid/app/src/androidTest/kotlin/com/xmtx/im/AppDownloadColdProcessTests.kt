package com.xmtx.im

import android.app.Application
import android.app.job.JobScheduler
import android.net.ConnectivityManager
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** Host observes the prepared process exit (killing it if needed), then runs the production service before cold App restoration. */
@OptIn(ExperimentalTestApi::class,ExperimentalCoroutinesApi::class)
class AppDownloadColdProcessTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>(effectContext=kotlinx.coroutines.test.StandardTestDispatcher())
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val args=InstrumentationRegistry.getArguments()
        init {assumeTrue("Requires explicit cold-download orchestration and opt-in Debug CA",args.getString("coldDownload")=="true")}
        val run=requireNotNull(args.getString("coldRun")).also {require(it.matches(Regex("[0-9a-f]{12}")))}
        val endpoint=requireNotNull(args.getString("e2eURL"));val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val credentials="cold-download-$run-credentials";val senderCredentials="cold-download-$run-sender"
        val preferences="cold-download-$run-endpoint"
        val metadata=File(context.noBackupFilesDir,"download-cold-$run.json")
        fun auth(name:String=credentials)=AuthSession(KeystoreSecretStore(context,name),AccountClient(endpoint))
        fun socket()=RealtimeConnection(URI(endpoint).host,port,authorPresentations=true)
    }
    @Test fun prepareReceivedAccountTaskForProcessDeath()=runBlocking<Unit> {
        val f=Fixture();check(!f.metadata.exists());assertNull(context.getSystemService(ConnectivityManager::class.java).activeNetwork)
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        val recipient=f.auth();val sender=f.auth(f.senderCredentials);val transport=AccountClient(f.endpoint)
        val senderSocket=f.socket();val receiverSocket=f.socket();val http=OkHttpClient()
        var senderStore:SqliteClientStore?=null;var receiverStore:SqliteClientStore?=null;var resources:AccountResourceActivity?=null;var published=false
        try {withTimeout(120000) {
            val password=id()+"aA1!"
            val a=recipient.login("cdd_${f.run}_a",password,true,"cdd_${f.run}_a","恢复下载 A")
            val b=sender.login("cdd_${f.run}_b",password,true,"cdd_${f.run}_b","恢复下载 B")
            check(context.getSharedPreferences(f.preferences,0).edit().putString("url",f.endpoint).commit())
            val db=openBoundFixtureStore(context,a.userId,a.deviceId);receiverStore=db
            val source=openBoundFixtureStore(context,b.userId,b.deviceId);senderStore=source
            val sourceApi=AuthenticatedApi(sender,transport,b.userId,b.deviceId);val api=AuthenticatedApi(recipient,transport,a.userId,a.deviceId)
            val directs=DirectRoomService(b.userId,DirectRoomClient(sourceApi),source);val command=directs.prepare(a.userId)
            var room:RoomId?=null
            while(room==null) {directs.flush();room=source.directWorks().first {it.command.operation==command.command.operation}.room;if(room==null) delay(250)}
            senderSocket.connect(sender.access());receiverSocket.connect(recipient.access())
            SyncEngine(senderSocket,source).synchronize();SyncEngine(receiverSocket,db).synchronize()
            val attachment=sendPeerAttachment(source,senderSocket,sourceApi,http,b.userId,room,f.run)
            while(db.snapshot().messages.none {it.id==attachment.message.id}) {RoomSyncEngine(receiverSocket,db).synchronize();delay(300)}
            ResourceDirectorySynchronizer(db,RoomResourceDirectoryClient(api)).refresh(room)
            val key=ResourceKey(ResourceHome.Room(room),attachment.asset.id)
            val work=db.enqueueResourceDownload(key,db.resourceSources(key).sources.single())
            val runtime=AccountResourceActivity(context,db,ResourceUploadClient(api,a.userId),targets=MediaDownloadTargetClient(api),download={_,_->error("Unexpected foreground transfer before handoff")})
            resources=runtime;val background=scope.async {runtime.runBackground()}
            var selected:Pair<ResourceBackgroundDownloadMapping,Int>?=null
            while(selected==null) {
                if(background.isCompleted) error("Background ended before native handoff")
                val mapping=db.activeBackgroundDownloads().singleOrNull()?.mapping
                val job=mapping?.let {m->context.getSystemService(JobScheduler::class.java).allPendingJobs.singleOrNull {it.extras.getString("task")==m.task}}
                if(mapping!=null && job!=null) {
                    assertEquals(ResourceDownloadJobService::class.java.name,job.service.className)
                    assertEquals(setOf("task"),job.extras.keySet());selected=mapping to job.id
                } else delay(20)
            }
            val (mapping,job)=selected
            assertTrue(db.resourceFiles().isEmpty());assertTrue(runtime.files.storageSnapshot().temporaryReservedBytes>0)
            f.metadata.writeText(buildJsonObject {
                put("run",f.run);put("actor",a.userId.value);put("device",a.deviceId.value);put("download",work.id)
                put("mapping",mapping.payload());put("pid",android.os.Process.myPid());put("job",job)
                put("displayName",attachment.asset.displayName);put("body",attachment.bytes)
            }.toString())
            published=true // Keep the recipient lease alive until process exit; do not gracefully close the account.
        }} finally {
            senderSocket.close();receiverSocket.close();senderStore?.close();sender.logout()
            http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()
            if(!published) {scope.cancel();resources?.close();receiverStore?.close();recipient.logout()}
        }
    }
    @Test fun coldAppPublishesNativeReceiptAndShowsCompletedDownloadInSharedNavigation() {
        val f=Fixture();val saved=Json.parseToJsonElement(f.metadata.readText()).jsonObject
        val actor=UserId(saved.getValue("actor").jsonPrimitive.content);val device=DeviceId(saved.getValue("device").jsonPrimitive.content)
        val mapping=ResourceBackgroundDownloadMapping.decode(saved.getValue("mapping").jsonObject)
        val download=saved.getValue("download").jsonPrimitive.content
        assertNotEquals(saved.getValue("pid").jsonPrimitive.int,android.os.Process.myPid())
        val driver=ResourceSystemDownloadDriver(context)
        runBlocking {
            val auth=f.auth();val credentials=requireNotNull(auth.current());assertEquals(actor,credentials.userId);assertEquals(device,credentials.deviceId)
            val receipt=driver.completions(mapping.systemSession).single();assertEquals(200,receipt.status);assertNull(receipt.issue)
            assertEquals(mapping.authorization.expectedBytes,receipt.receivedBytes);assertEquals(mapping.originDigest,receipt.originDigest)
            openBoundFixtureStore(context,actor,device).use {db->assertTrue(db.resourceFiles().isEmpty());assertTrue(db.resourceDownloads().single().work.backgroundPending)}
        }
        val targets=AtomicInteger();val byteDownloads=AtomicInteger()
        val http=OkHttpClient.Builder().addInterceptor {chain->
            if(chain.request().url.encodedPath=="/v2/media/${mapping.key.media}") targets.incrementAndGet()
            chain.proceed(chain.request())
        }.build()
        val dependencies=AppDependencies(account={AccountClient(it,http)},realtime={f.socket()},preferencesName=f.preferences,credentialsName=f.credentials,
            download={target,file->byteDownloads.incrementAndGet();MediaFileDownloader().download(target,file)})
        var model:AppViewModel?=null;val models=ViewModelStore();var displayed by mutableStateOf<AppViewModel?>(null)
        try {
            compose.runOnUiThread {model=AppViewModel(context.applicationContext as Application,dependencies);models.put("cold-download",model!!);displayed=model}
            val restoration=StateRestorationTester(compose);restoration.setContent {displayed?.let {ApplicationContent(it)}}
            compose.waitUntil(45000) {model!!.state.value.session==SessionUi.SignedIn(actor)}
            compose.onNodeWithTag("conversation-list").assertExists()
            compose.onNodeWithText("我的").performClick();compose.onNodeWithText("资源中心").performScrollTo().performClick()
            compose.waitUntil(15000) {model!!.state.value.resourceLibrary.entries.any {it.descriptor.key==mapping.key}}
            compose.onNodeWithTag("resource-library-list").performScrollToNode(hasTestTag("resource-entry-${mapping.key.media}"))
            compose.onNodeWithTag("resource-entry-${mapping.key.media}").performClick()
            compose.waitUntil(15000) {model!!.state.value.resourceDetail?.usable==true}
            compose.onNodeWithTag("resource-download-tasks").performScrollTo().performClick()
            compose.waitUntil(45000) {model!!.state.value.resourceDownloads.entries.any {it.work.id==download && it.work.phase==ResourceDownloadPhase.Completed}}
            assertEquals(0,byteDownloads.get());assertTrue(targets.get()>0)
            compose.onNodeWithTag("resource-downloads").performScrollToNode(hasTestTag("download-$download"))
            compose.onNodeWithTag("download-status-$download").assertTextEquals("下载完成")
            restoration.emulateSavedInstanceStateRestore()
            compose.waitUntil(15000) {model!!.state.value.resourceDownloads.entries.any {it.work.id==download && it.work.phase==ResourceDownloadPhase.Completed}}
            compose.onNodeWithTag("resource-downloads").performScrollToNode(hasTestTag("download-$download"))
            capture("download-cold-${f.run}-tasks.png")
            compose.onNode(hasText("查看资源") and hasAnyAncestor(hasTestTag("download-$download"))).performClick()
            compose.waitUntil(15000) {model!!.state.value.resourceDetail?.let {it.usable && it.original?.availableLocally==true}==true}
            capture("download-cold-${f.run}-detail.png")
            compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithTag("resource-downloads").assertExists()
        } finally {
            compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
            model?.let {owner->val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
                try {val closed=scope.async {owner.awaitShutdown()};compose.waitUntil(15000) {closed.isCompleted};runBlocking {closed.await()}} finally {scope.cancel()}}
            http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()
        }
        runBlocking {
            val db=openBoundFixtureStore(context,actor,device);val files=ManagedResourceFiles(context,db)
            try {
                assertEquals(ResourceDownloadPhase.Completed,db.resourceDownloads().single().work.phase)
                assertTrue(db.activeBackgroundDownloads().isEmpty());assertTrue(driver.completions(mapping.systemSession).isEmpty())
                assertEquals(0L,files.storageSnapshot().temporaryReservedBytes);assertTrue(db.pending().isEmpty())
                val current=f.auth().current()!!;val reader=MessageOriginalFiles(MediaDownloadTargetClient(AuthenticatedApi(f.auth(),AccountClient(f.endpoint),current.userId,current.deviceId)),db,files)
                try {assertEquals(saved.getValue("body").jsonPrimitive.content,reader.withOriginal(mapping.key,cacheOnly=true,message=mapping.message) {_,file->file.readText()})} finally {reader.close()}
            } finally {files.close();db.close()}
        }
        File(context.noBackupFilesDir,"download-cold-${f.run}-verified.json").writeText(buildJsonObject {
            put("preparedPid",saved.getValue("pid"));put("appPid",android.os.Process.myPid());put("nativeStatus",200)
            put("freshTargets",targets.get());put("foregroundByteDownloads",byteDownloads.get());put("completed",true);put("temporaryReservedBytes",0)
        }.toString())
    }
    @Test fun cleanupColdDownloadFixture()=runBlocking<Unit> {
        val f=Fixture();val auth=f.auth()
        try {auth.current()?.let {credentials->
            val db=openBoundFixtureStore(context,credentials.userId,credentials.deviceId);val files=ManagedResourceFiles(context,db);val driver=ResourceSystemDownloadDriver(context)
            try {
                for(snapshot in db.activeBackgroundDownloads()) {db.controlResourceDownload(snapshot.mapping.download,ResourceDownloadControl.Cancel);driver.cancelAndDrain(snapshot.mapping)}
                driver.reconcile(db,files);assertTrue(db.activeBackgroundDownloads().isEmpty());assertEquals(0L,files.storageSnapshot().temporaryReservedBytes)
            } finally {files.close();db.close()}
        }} finally {auth.logout();f.auth(f.senderCredentials).logout()}
    }
    private fun capture(name:String) {
        compose.waitForIdle();val bitmap=requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try {context.openFileOutput(name,0).use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}} finally {bitmap.recycle()}
    }
}
