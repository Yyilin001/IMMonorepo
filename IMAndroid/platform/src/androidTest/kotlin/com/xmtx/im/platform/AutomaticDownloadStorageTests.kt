package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class AutomaticDownloadStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private val bodies=mutableMapOf<String,String>()
    private fun descriptor(body:String=id(),type:String="text/plain"):ResourceDescriptor {
        val value=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"资源",type,body.length.toLong(),ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(body.toByteArray()).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
        bodies[value.key.media]=body;return value
    }
    private suspend fun catalog(store:SqliteClientStore,vararg values:ResourceDescriptor) {
        store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(values.mapIndexed {i,value->RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-i,0,value.key.media),1000,value)}.toPersistentList(),100,null))
    }
    private suspend fun enable(store:SqliteClientStore,categories:PersistentSet<ResourceCategory> = persistentSetOf(ResourceCategory.File),maximum:Long=10L*1024*1024) {
        store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(automaticDownloads=ResourceAutomaticDownloadPolicy(categories,maximum)))
    }
    private suspend fun jobs(store:SqliteClientStore)=store.resourceDownloads().map {it.work}
    private suspend fun until(predicate:suspend ()->Boolean)=withTimeout(15000) {while(!predicate()) delay(10)}
    @Test fun onlyEligibleVisibleSourcesAreAdmittedAndBookkeepingPreservesReadEvidence()=runBlocking {
        val store=store();val eligible=descriptor("small","image/png");val file=descriptor("small file");val large=descriptor("x".repeat(101),"image/png")
        try {
            catalog(store,eligible,file,large);store.prepareAutomaticDownloads(1000,true);assertTrue(jobs(store).isEmpty())
            enable(store,persistentSetOf(ResourceCategory.Image),100)
            val evidence=store.selectMessageResource(eligible.key)
            store.prepareAutomaticDownloads(1000,true)
            val job=jobs(store).single();assertTrue(job.automatic);assertEquals(eligible,job.descriptor)
            assertTrue(store.isMessageResourceCurrent(evidence))
            store.unavailable(room);assertNull(store.claimResourceDownload(job.id,id(),1001));assertEquals(ResourceDownloadIssue.Unavailable,jobs(store).single().issue)
            store.prepareAutomaticDownloads(1002,true);assertEquals(1,jobs(store).size)
        } finally {store.close()}
    }
    @Test fun automaticLimitReservesFourManualSlotsAndEachPassIsBounded()=runBlocking {
        val store=store();val values=(1..17).map {descriptor("content-$it")}
        try {
            catalog(store,*values.toTypedArray());enable(store)
            store.prepareAutomaticDownloads(1000,false);assertEquals(2,jobs(store).size)
            repeat(10) {store.prepareAutomaticDownloads(1001L+it,false)}
            assertEquals(12,jobs(store).size);assertTrue(jobs(store).all {it.automatic && it.attempts==0})
            val chosen=jobs(store).map {it.descriptor.key}.toSet();val manual=values.filter {it.key !in chosen}
            manual.take(4).forEach {store.enqueueResourceDownload(it.key,store.resourceSources(it.key).sources.single(),2000)}
            assertEquals(16,jobs(store).size)
            assertTrue(runCatching {store.enqueueResourceDownload(manual.last().key,store.resourceSources(manual.last().key).sources.single(),2000)}.isFailure)
        } finally {store.close()}
    }
    @Test fun identicalBytesHaveOneTaskAndCancelledAdmissionSurvivesReopen()=runBlocking {
        var store=store();val first=descriptor("same");val second=descriptor("same")
        try {
            catalog(store,first,second);enable(store);store.prepareAutomaticDownloads(1000,true)
            val only=jobs(store).single();store.controlResourceDownload(only.id,ResourceDownloadControl.Cancel,1001)
            store.close();store=store();store.prepareAutomaticDownloads(1002,true)
            assertEquals(listOf(only.id),jobs(store).map {it.id});assertEquals(ResourceDownloadPhase.Stopped,jobs(store).single().phase)
            assertEquals(persistentSetOf(ResourceCategory.File),store.downloadNetworkPreferences().automaticDownloads.categories)
        } finally {store.close()}
    }
    @Test fun manualPromotionKeepsOriginalSourceAttemptsAndRetryFloor()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);enable(store);store.prepareAutomaticDownloads(1000,true)
            val job=jobs(store).single();val claim=store.claimResourceDownload(job.id,id(),1001)!!
            store.releaseResourceDownload(claim,ResourceDownloadIssue.Network,9000,8000,false,1002)
            val old=jobs(store).single();val promoted=store.enqueueResourceDownload(value.key,store.resourceSources(value.key).sources.single(),1003)
            assertEquals(old.copy(automatic=false),promoted);assertEquals(1,jobs(store).size)
            assertNull(store.claimResourceDownload(job.id,id(),8999))
        } finally {store.close()}
    }
    @Test fun policyChangesDoNotResumePausedWorkOrResetExhaustedAttempts()=runBlocking {
        val store=store();val values=listOf(descriptor(),descriptor())
        try {
            catalog(store,*values.toTypedArray());enable(store);store.prepareAutomaticDownloads(1000,true)
            val a=jobs(store)[0];val b=jobs(store)[1]
            store.controlResourceDownload(a.id,ResourceDownloadControl.Pause,1001)
            for(attempt in 1..5) {
                val claim=store.claimResourceDownload(b.id,id(),1001L+attempt)!!
                store.releaseResourceDownload(claim,ResourceDownloadIssue.Policy,null,0,false,1001L+attempt)
                store.prepareAutomaticDownloads(1001L+attempt,true)
            }
            assertEquals(5,jobs(store).first {it.id==b.id}.attempts);assertFalse(jobs(store).first {it.id==b.id}.requested)
            enable(store,persistentSetOf());store.prepareAutomaticDownloads(2000,true);enable(store);store.prepareAutomaticDownloads(2001,true)
            assertEquals(ResourceDownloadControl.Pause,jobs(store).first {it.id==a.id}.control)
            assertFalse(jobs(store).first {it.id==b.id}.requested)
        } finally {store.close()}
    }
    @Test fun upgradingLegacyDownloadRowsAndNetworkSettingsKeepsManualIntent()=runBlocking {
        var store=store();val value=descriptor()
        try {
            catalog(store,value);store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(false,true))
            val work=store.enqueueResourceDownload(value.key,store.resourceSources(value.key).sources.single(),1000)
            store.close()
            val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
            SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use {db->
                db.execSQL("ALTER TABLE resource_downloads RENAME TO download_new")
                db.execSQL("CREATE TABLE resource_downloads(id TEXT PRIMARY KEY,descriptor TEXT NOT NULL,room TEXT NOT NULL,message TEXT NOT NULL,created INTEGER NOT NULL,phase TEXT NOT NULL,control TEXT NOT NULL,requested INTEGER NOT NULL,attempts INTEGER NOT NULL,owner TEXT,claim TEXT,issue TEXT,retry INTEGER NOT NULL,server_retry INTEGER NOT NULL,finished INTEGER)")
                db.execSQL("INSERT INTO resource_downloads SELECT id,descriptor,room,message,created,phase,control,requested,attempts,owner,claim,issue,retry,server_retry,finished FROM download_new")
                db.execSQL("DROP TABLE download_new")
                db.execSQL("ALTER TABLE resource_download_network RENAME TO network_new")
                db.execSQL("CREATE TABLE resource_download_network(singleton INTEGER PRIMARY KEY,cellular INTEGER NOT NULL,constrained INTEGER NOT NULL)")
                db.execSQL("INSERT INTO resource_download_network SELECT singleton,cellular,constrained FROM network_new")
                db.execSQL("DROP TABLE network_new")
            }
            store=store();assertEquals(work,jobs(store).single());assertEquals(ResourceDownloadNetworkPreferences(false,true),store.downloadNetworkPreferences())
            enable(store);store.prepareAutomaticDownloads(1001,true);assertEquals(listOf(work),jobs(store))
        } finally {store.close()}
    }
    @Test fun publishedVerifiedBytesDoNotCreateAutomaticWork()=runBlocking {
        val store=store();val value=descriptor("cached");val targets=targets(listOf(value));val files=ManagedResourceFiles(context,store,download={_,file->file.writeText("cached")})
        try {
            catalog(store,value);val read=store.selectMessageResource(value.key)
            files.withDownloaded(targets.resolve(value.key.media,MediaMessageLocation(room,read.source.message),null)) {}
            enable(store);store.prepareAutomaticDownloads(1000,true);assertTrue(jobs(store).isEmpty())
        } finally {files.close();store.close()}
    }
    private fun targets(values:List<ResourceDescriptor>)=MediaDownloadTargetClient(object:AuthenticatedTransport {
        override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("No replayable request")
        override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long):EdgeResponse {
            val value=values.first {path.contains(it.key.media,ignoreCase=true)}
            return EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                put("version",1);put("mode","http_get");put("url","https://provider.invalid/${value.key.media}");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                put("expiresAtUnixMilliseconds",System.currentTimeMillis()+60000);put("expectedByteCount",value.byteCount);put("checksum",value.checksum!!.payload())
            })})
        }
    })
    private val uploads=object:ResourceUploadControl {
        override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession=error("No upload")
        override suspend fun status(previous:ResourceUploadSession):ResourceUploadSession=error("No upload")
        override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest):ResourceTransferPlan?=error("No upload")
        override suspend fun finalize(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
        override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession=error("No upload")
    }
    @Test fun accountRuntimeCarriesAutomaticPolicyToWriterAndPreservesManualExecutionSlot()=runBlocking {
        val store=store();val a=descriptor("auto-a","image/png");val b=descriptor("auto-b","image/png");val manual=descriptor("manual")
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>();var automatic=0;var manualCount=0
        val activity=AccountResourceActivity(context,store,uploads,automaticNetwork={true},targets=targets(listOf(a,b,manual)),download={target,file->
            val marker=currentCoroutineContext()[AutomaticResourceDownload]
            if(marker!=null) {automatic++;assertEquals(marker.descriptor.checksum,target.plan.checksum);entered.complete(Unit);release.await()}
            else manualCount++
            val key=listOf(a,b,manual).first {it.checksum==target.plan.checksum}.key.media
            file.writeText(bodies.getValue(key))
        })
        var run:Job?=null
        try {
            catalog(store,a,b,manual);enable(store,persistentSetOf(ResourceCategory.Image));run=launch {activity.runForeground()};entered.await()
            // Explicit request upgrades an already admitted automatic identity if the observer won the race.
            val work=store.enqueueResourceDownload(manual.key,store.resourceSources(manual.key).sources.single())
            until {jobs(store).first {it.id==work.id}.terminal}
            assertEquals(1,automatic);assertEquals(1,manualCount)
            release.complete(Unit);until {jobs(store).count {it.phase==ResourceDownloadPhase.Completed}==3}
            assertEquals(2,automatic)
        } finally {release.complete(Unit);run?.cancelAndJoin();activity.close();store.close()}
    }
    @Test fun backgroundOnlyDoesNotAdmitAndOfflineForegroundDoesNotChargeAttempts()=runBlocking {
        val store=store();val value=descriptor("offline");var network=false;var calls=0
        val activity=AccountResourceActivity(context,store,uploads,automaticNetwork={network},targets=targets(listOf(value)),download={_,file->calls++;file.writeText("offline")})
        var run:Job?=null
        try {
            catalog(store,value);enable(store)
            activity.runBackground(1000);assertTrue(jobs(store).isEmpty());assertEquals(0,calls)
            run=launch {activity.runForeground()};until {jobs(store).size==1}
            assertEquals(0,jobs(store).single().attempts);assertNull(jobs(store).single().owner);assertEquals(0,calls)
            val waiting=activity.transferWaiting.state.value[ResourceTransferId(ResourceTransferKind.Download,jobs(store).single().id)]
            assertTrue(waiting==ResourceTransferWaitingReason.Network || waiting==ResourceTransferWaitingReason.NetworkPolicy)
            network=true;enable(store)
            until {jobs(store).single().terminal};assertEquals(1,calls);assertEquals(1,jobs(store).single().attempts)
        } finally {run?.cancelAndJoin();activity.close();store.close()}
    }

}
