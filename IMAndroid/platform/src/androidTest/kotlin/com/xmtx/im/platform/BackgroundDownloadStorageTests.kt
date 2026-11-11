package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID

class BackgroundDownloadStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private val text="delegated-original"
    private fun descriptor()=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"原件.txt","text/plain",text.length.toLong(),
        ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") {"%02x".format(it)}),ResourceState.Ready)
    private suspend fun catalog(store:SqliteClientStore,vararg values:ResourceDescriptor) {
        store.applyResourceDirectoryPage(store.beginResourceDirectoryScan(room),RoomResourcePage(values.mapIndexed {i,value->
            RoomResourceItem(MessageId(id()),1,RoomResourcePosition(100L-i,0,value.key.media),1000,value)}.toPersistentList(),100,null))
    }
    private suspend fun enqueue(store:SqliteClientStore,value:ResourceDescriptor)=store.enqueueResourceDownload(value.key,store.resourceSources(value.key).sources.single())
    private suspend fun work(store:SqliteClientStore,id:String)=store.resourceDownloads().first {it.work.id==id}.work
    private suspend fun target(value:ResourceDescriptor,now:Long=System.currentTimeMillis()):ResourceBackgroundDownloadTarget {
        val grant=ResourceBackgroundDownloadAuthorization(id(),value.byteCount,value.checksum!!,now,now+60000)
        val resolver=MediaDownloadTargetClient(object:AuthenticatedTransport {
            override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse=error("unused")
            override suspend fun mediaTarget(path:String,query:Map<String,String>,maximumBytes:Long)=EdgeResponse(200,buildJsonObject {put("plan",buildJsonObject {
                put("version",1);put("mode","http_get");put("url","https://download.invalid/original?secret=capability");put("headers",JsonArray(emptyList()));put("formFields",JsonObject(emptyMap()))
                put("expiresAtUnixMilliseconds",grant.expiresAt);put("expectedByteCount",value.byteCount);put("checksum",requireNotNull(value.checksum).payload());put("backgroundDownloadAuthorization",grant.payload())
            })})
        },now={now})
        return ResourceBackgroundDownloadTarget(resolver.resolve(value.key.media,null,null))
    }
    private suspend fun install(store:SqliteClientStore,value:ResourceDescriptor):Pair<ResourceDownloadClaim,ResourceBackgroundDownloadMapping> {
        val job=enqueue(store,value);val claim=store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!
        return claim to store.installBackgroundDownload(claim,id(),id(),target(value))
    }
    private fun success(mapping:ResourceBackgroundDownloadMapping)=ResourceBackgroundDownloadResult(mapping.id,mapping.task,200,null,mapping.authorization.expectedBytes,mapping.originDigest)

    @Test fun delegationPersistsAcrossReopenAndInvalidatesForegroundClaimWithoutRestarting()=runBlocking {
        var store=store();val value=descriptor()
        try {
            catalog(store,value);val (claim,mapping)=install(store,value)
            assertTrue(work(store,claim.work.id).backgroundPending);assertNull(work(store,claim.work.id).owner)
            store.releaseResourceDownload(claim,ResourceDownloadIssue.Network,null,0,true,System.currentTimeMillis())
            assertTrue(work(store,claim.work.id).backgroundPending)
            store.close();store=store();assertEquals(mapping.systemSession,store.backgroundDownloadSession())
            assertEquals(persistentListOf(ResourceBackgroundDownloadSnapshot(mapping,false)),store.activeBackgroundDownloads())
            store.recoverResourceDownloads(id(),System.currentTimeMillis())
            assertNull(store.claimResourceDownload(claim.work.id,id(),System.currentTimeMillis()+100000))
            assertEquals(1,work(store,claim.work.id).attempts);assertFalse(mapping.payload().toString().contains("capability"))
            assertTrue(store.finishBackgroundDownload(mapping,null));assertFalse(work(store,claim.work.id).backgroundPending)
        } finally {store.close()}
    }
    @Test fun pauseAndCancelWaitForPhysicalDrainBeforeResumeOrRetirement()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);val (_,mapping)=install(store,value)
            store.controlResourceDownload(mapping.download,ResourceDownloadControl.Pause)
            assertTrue(runCatching {store.controlResourceDownload(mapping.download,ResourceDownloadControl.Run)}.isFailure)
            assertTrue(store.finishBackgroundDownload(mapping,success(mapping)))
            val paused=work(store,mapping.download);assertEquals(ResourceDownloadControl.Pause,paused.control);assertFalse(paused.backgroundPending);assertFalse(paused.requested)
            store.controlResourceDownload(mapping.download,ResourceDownloadControl.Run)
            val claim=store.claimResourceDownload(mapping.download,id(),System.currentTimeMillis())!!
            val next=store.installBackgroundDownload(claim,id(),id(),target(value))
            store.controlResourceDownload(mapping.download,ResourceDownloadControl.Cancel)
            assertFalse(work(store,mapping.download).terminal);assertFalse(store.finishBackgroundDownload(mapping,success(mapping)))
            assertTrue(store.finishBackgroundDownload(next,null));assertEquals(ResourceDownloadPhase.Stopped,work(store,mapping.download).phase)
            assertTrue(store.activeBackgroundDownloads().isEmpty())
        } finally {store.close()}
    }
    @Test fun receivedBytesNeedVerifiedPublicationAndFreshAuthorityBeforeCompletion()=runBlocking {
        var store=store();val value=descriptor();var files:ManagedResourceFiles?=null
        try {
            catalog(store,value);val (_,mapping)=install(store,value);val evidence=store.selectMessageResource(value.key)
            assertFalse(store.completeBackgroundDownload(mapping,evidence))
            assertTrue(store.finishBackgroundDownload(mapping,success(mapping)));assertTrue(store.activeBackgroundDownloads().single().received)
            assertTrue(runCatching {store.completeBackgroundDownload(mapping,evidence)}.isFailure)
            assertFalse(store.finishBackgroundDownload(mapping,null));assertFalse(work(store,mapping.download).terminal)
            store.close();store=store();assertTrue(store.activeBackgroundDownloads().single().received)
            files=ManagedResourceFiles(context,store,download={_,file->file.writeText(text)})
            files.withDownloaded(target(value).target) {}
            assertTrue(store.completeBackgroundDownload(mapping,store.selectMessageResource(value.key)))
            assertEquals(ResourceDownloadPhase.Completed,work(store,mapping.download).phase)
            assertFalse(store.completeBackgroundDownload(mapping,evidence));assertFalse(store.finishBackgroundDownload(mapping,success(mapping)))
        } finally {files?.close();store.close()}
    }
    @Test fun revocationPreventsPublishingReceivedBytesAndStillAllowsDraining()=runBlocking {
        val store=store();val value=descriptor();val files=ManagedResourceFiles(context,store,download={_,file->file.writeText(text)})
        try {
            catalog(store,value);val (_,mapping)=install(store,value);val old=store.selectMessageResource(value.key)
            assertTrue(store.finishBackgroundDownload(mapping,success(mapping)));files.withDownloaded(target(value).target) {}
            store.unavailable(room)
            assertTrue(runCatching {store.completeBackgroundDownload(mapping,old)}.isFailure)
            assertTrue(store.finishBackgroundDownload(mapping,null));val work=work(store,mapping.download)
            assertFalse(work.requested);assertEquals(ResourceDownloadIssue.Unavailable,work.issue)
            store.controlResourceDownload(work.id,ResourceDownloadControl.Cancel);assertTrue(work(store,work.id).terminal)
        } finally {files.close();store.close()}
    }
    @Test fun physicalFailuresPreserveServerFloorAndSpendTheOriginalFiveAttemptBudget()=runBlocking {
        val store=store();val value=descriptor();val now=System.currentTimeMillis();var wall=now
        try {
            catalog(store,value);val job=enqueue(store,value)
            for(attempt in 1..5) {
                val claim=store.claimResourceDownload(job.id,id(),wall)!!
                val mapping=store.installBackgroundDownload(claim,id(),id(),target(value,wall),wall)
                val floor=wall+60000
                assertTrue(store.finishBackgroundDownload(mapping,ResourceBackgroundDownloadResult(mapping.id,mapping.task,429,null,0,mapping.originDigest,floor),wall))
                val result=work(store,job.id);assertEquals(attempt,result.attempts);assertEquals(floor,result.serverRetryAt);assertTrue(result.retryAt>=floor)
                assertNull(store.claimResourceDownload(job.id,id(),floor-1));assertEquals(attempt,enqueue(store,value).attempts)
                wall=result.retryAt
            }
            assertFalse(work(store,job.id).requested);assertNull(store.claimResourceDownload(job.id,id(),wall+100000))
        } finally {store.close()}
    }
    @Test fun badIdentitiesCannotTouchMappingAndWrongOriginCannotSupplyRetryFloor()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);val (_,mapping)=install(store,value)
            assertFalse(store.finishBackgroundDownload(mapping,success(mapping).copy(task=id())))
            assertFalse(store.finishBackgroundDownload(mapping.copy(id=id()),success(mapping)))
            assertTrue(work(store,mapping.download).backgroundPending)
            assertTrue(store.finishBackgroundDownload(mapping,success(mapping).copy(originDigest="b".repeat(64),retryNotBefore=Long.MAX_VALUE)))
            val row=work(store,mapping.download);assertFalse(row.requested);assertEquals(ResourceDownloadIssue.Integrity,row.issue);assertEquals(0L,row.serverRetryAt)
        } finally {store.close()}
    }
    @Test fun automaticHandoffFreezesStrictNetworkPolicyAndRejectsDisabledCategory()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true,ResourceAutomaticDownloadPolicy(persistentSetOf(ResourceCategory.File))))
            store.prepareAutomaticDownloads(System.currentTimeMillis(),true);val job=store.resourceDownloads().single().work
            val claim=store.claimResourceDownload(job.id,id(),System.currentTimeMillis())!!
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true))
            assertTrue(runCatching {store.installBackgroundDownload(claim,id(),id(),target(value))}.exceptionOrNull() is ResourceDownloadPolicyRestricted)
            assertEquals(claim.work,work(store,job.id));assertTrue(store.activeBackgroundDownloads().isEmpty())
            store.setDownloadNetworkPreferences(ResourceDownloadNetworkPreferences(true,true,ResourceAutomaticDownloadPolicy(persistentSetOf(ResourceCategory.File))))
            val mapping=store.installBackgroundDownload(claim,id(),id(),target(value))
            assertEquals(ResourceDownloadNetworkConstraints(false,false,false),mapping.constraints)
            enqueue(store,value);assertFalse(work(store,job.id).automatic);assertEquals(mapping,store.activeBackgroundDownloads().single().mapping)
            assertTrue(store.finishBackgroundDownload(mapping,null))
        } finally {store.close()}
    }
    @Test fun publicationFailureUsesExplicitReceivedTransitionAndNeverAutomaticRetry()=runBlocking {
        val store=store();val value=descriptor()
        try {
            catalog(store,value);val (_,mapping)=install(store,value)
            assertFalse(store.discardReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Integrity))
            store.finishBackgroundDownload(mapping,success(mapping))
            assertTrue(store.discardReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Integrity))
            assertFalse(work(store,mapping.download).requested);assertEquals(ResourceDownloadIssue.Integrity,work(store,mapping.download).issue)
            assertFalse(store.discardReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Storage))
        } finally {store.close()}
    }
    @Test fun failedInstallationRollsBackAndAccountDeviceSessionsAreIndependent()=runBlocking {
        val store=store();val other=SqliteClientStore(context,actor,DeviceId(id()));val value=descriptor()
        try {
            catalog(store,value);val (old,mapping)=install(store,value);store.finishBackgroundDownload(mapping,null)
            val claim=store.claimResourceDownload(old.work.id,id(),System.currentTimeMillis()+60000)!!
            assertTrue(runCatching {store.installBackgroundDownload(claim,mapping.id,id(),target(value))}.isFailure)
            assertEquals(claim.work,work(store,claim.work.id));assertTrue(store.activeBackgroundDownloads().isEmpty())
            assertNotEquals(store.backgroundDownloadSession(),other.backgroundDownloadSession());assertTrue(other.activeBackgroundDownloads().isEmpty())
        } finally {other.close();store.close()}
    }
    @Test fun receivedAuthorizationRetriesPersistTheirBudgetAndServerFloorWithoutReclaimingBytes()=runBlocking {
        var store=store();val value=descriptor()
        try {
            catalog(store,value);val (_,mapping)=install(store,value);val now=System.currentTimeMillis();val floor=now+60000
            assertFalse(store.failReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Network,now+1000,floor))
            store.finishBackgroundDownload(mapping,success(mapping))
            repeat(4) {
                assertTrue(store.failReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Network,now+1000,if(it==0) floor else 0))
                store.close();store=store()
                val work=work(store,mapping.download);assertEquals(it+2,work.attempts);assertTrue(work.requested && work.backgroundPending)
                assertEquals(floor,work.serverRetryAt);assertTrue(work.retryAt>=floor);assertTrue(store.activeBackgroundDownloads().single().received)
                assertFalse(store.finishBackgroundDownload(mapping,null));assertNull(store.claimResourceDownload(work.id,id(),floor+1000))
            }
            assertTrue(store.failReceivedBackgroundDownload(mapping,ResourceDownloadIssue.Network,now+1000,0))
            val stopped=work(store,mapping.download);assertEquals(5,stopped.attempts);assertFalse(stopped.requested || stopped.backgroundPending)
            assertTrue(store.activeBackgroundDownloads().isEmpty());assertEquals(floor,stopped.serverRetryAt)
            store.controlResourceDownload(stopped.id,ResourceDownloadControl.Run)
            assertNull(store.claimResourceDownload(stopped.id,id(),floor-1));assertNotNull(store.claimResourceDownload(stopped.id,id(),floor))
        } finally {store.close()}
    }
}
