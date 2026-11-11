package com.xmtx.im.client

import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import java.io.IOException
import java.util.UUID
import kotlin.test.*

class ResourceDownloadIntentTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun work(automatic:Boolean):ResourceDownloadWork {
        val room=RoomId(id())
        return ResourceDownloadWork(id(),ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"file.txt","text/plain",8,
            ResourceChecksum("a".repeat(64)),ResourceState.Ready),MediaMessageLocation(room,MessageId(id())),0,automatic=automatic)
    }
    private class Journal(var work:ResourceDownloadWork):ResourceDownloadJournal {
        override val resourceDownloadChanges=MutableStateFlow(0L)
        var released=CompletableDeferred<Unit>()
        override suspend fun resourceDownloads()=persistentListOf(ResourceDownloadSnapshot(work,true))
        override suspend fun enqueueResourceDownload(key:ResourceKey,source:MessageResourceSource,now:Long)=error("unused")
        override suspend fun controlResourceDownload(id:String,control:ResourceDownloadControl,now:Long)=error("unused")
        override suspend fun recoverResourceDownloads(owner:String,now:Long) {}
        override suspend fun claimResourceDownload(id:String,owner:String,now:Long):ResourceDownloadClaim? {
            if(!work.requested || work.phase!=ResourceDownloadPhase.Pending) return null
            work=work.copy(phase=ResourceDownloadPhase.Running,owner=owner,claim=UUID.randomUUID().toString().uppercase(),attempts=work.attempts+1)
            return ResourceDownloadClaim(work)
        }
        override suspend fun completeResourceDownload(claim:ResourceDownloadClaim,read:MessageResourceRead,now:Long)=error("unused")
        override suspend fun releaseResourceDownload(claim:ResourceDownloadClaim,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,interrupted:Boolean,now:Long) {
            work=work.copy(phase=ResourceDownloadPhase.Pending,owner=null,claim=null,requested=false,issue=issue)
            released.complete(Unit);resourceDownloadChanges.value++
        }
        fun resumeManually() {
            work=work.copy(automatic=false,attempts=0,requested=true,issue=null)
            released=CompletableDeferred();resourceDownloadChanges.value++
        }
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun `offline automatic intent reports network policy changes without claiming attempts`()=runTest {
        val store=Journal(work(true));val hub=ResourceTransferWaiting();var allowed=false
        var reason=ResourceTransferWaitingReason.Network;var calls=0
        val run=launch {ResourceDownloadService(store,now={1000},automaticNetwork={allowed},waiting=hub,automaticWaiting={reason}) {_,_->
            calls++;throw IOException("fixture interruption")
        }.runForeground()}
        val id=ResourceTransferId(ResourceTransferKind.Download,store.work.id)
        try {
            runCurrent();assertEquals(ResourceTransferWaitingReason.Network,hub.state.value[id]);assertEquals(0,store.work.attempts)
            val old=hub.state.value;reason=ResourceTransferWaitingReason.NetworkPolicy;advanceTimeBy(5000);runCurrent()
            assertEquals(ResourceTransferWaitingReason.NetworkPolicy,hub.state.value[id]);assertEquals(ResourceTransferWaitingReason.Network,old[id]);assertEquals(0,calls)
            allowed=true;advanceTimeBy(5000);runCurrent();assertEquals(1,calls);assertTrue(hub.state.value.isEmpty())
        } finally {run.cancelAndJoin();assertTrue(hub.state.value.isEmpty());hub.close()}
    }
    @Test fun `durable downloads retain retry classification through initial work and manual counter resets`()=runTest {
        for(automatic in listOf(false,true)) {
            val store=Journal(work(automatic));var calls=0
            val service=ResourceDownloadService(store,now={1000},automaticNetwork={true}) {claim,_->
                calls++
                val intent=assertNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(intent.isRetry)
                assertEquals(if(claim.work.automatic) NetworkWorkPriority.Background else NetworkWorkPriority.Interactive,intent.priority)
                assertEquals(claim.work.automatic,currentCoroutineContext()[AutomaticResourceDownload]!=null)
                assertEquals(1,claim.work.attempts)
                throw IOException("fixture interrupted download")
            }
            val run=launch(NetworkWorkIntent(NetworkWorkPriority.Background,false)) {service.runForeground()}
            try {
                store.released.await();store.resumeManually();store.released.await();assertEquals(2,calls)
            } finally {run.cancelAndJoin()}
        }
    }
    @Test fun `cancelled generation releases its claim and resumed work remains a retry`()=runTest {
        val store=Journal(work(false));val entered=CompletableDeferred<Unit>()
        val first=launch {ResourceDownloadService(store,now={1000}) {_,_->
            assertTrue(assertNotNull(currentCoroutineContext()[NetworkWorkIntent]).isRetry)
            entered.complete(Unit);awaitCancellation()
        }.runForeground()}
        entered.await();first.cancelAndJoin();assertNull(store.work.owner);assertEquals(ResourceDownloadIssue.Interrupted,store.work.issue)
        store.resumeManually()
        val resumed=launch {ResourceDownloadService(store,now={1000}) {_,_->
            val intent=assertNotNull(currentCoroutineContext()[NetworkWorkIntent]);assertTrue(intent.isRetry)
            assertEquals(NetworkWorkPriority.Interactive,intent.priority);throw IOException("fixture interruption")
        }.runForeground()}
        try {store.released.await()} finally {resumed.cancelAndJoin()}
    }
}
