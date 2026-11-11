package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID

/** Owns native handoff and fresh publication; no network authorization is performed under the lifecycle mutex. */
internal class AccountSystemDownloads(context:android.content.Context,private val store:SqliteClientStore,
    private val files:ManagedResourceFiles,private val targets:MediaTargetResolving?,private val driver:ResourceSystemDownloadDriver,
    private val admission:AccountSystemTransferAdmission,private val waiting:ResourceTransferWaiting?=null) {
    private val context=context.applicationContext
    private val mutex=Mutex();private var enabled=false;private var closed=false
    private val publications=mutableMapOf<String,Job>()
    private val preparing=mutableSetOf<String>()
    suspend fun enable()=mutex.withLock {check(!closed);enabled=true}
    suspend fun canDelegate()=mutex.withLock {!closed && enabled && targets!=null}
    suspend fun delegate(claim:ResourceDownloadClaim,target:MediaDownloadTarget):Boolean {
        val grant=target.plan.backgroundDownload ?: return false
        if(!canDelegate()) return false
        // The Swift download contract treats issuedAt as not-before. Small server/device clock skew
        // can be waited out without extending the plan or holding the account lifecycle mutex.
        val ahead=grant.issuedAt-System.currentTimeMillis()
        if(ahead>0) {
            if(ahead>5000) return false
            delay(ahead)
            target.requireValid()
            if(System.currentTimeMillis()<grant.issuedAt) return false
        }
        val delegated=ResourceBackgroundDownloadTarget(target)
        val mapping=mutex.withLock {
        if(closed || !enabled || targets==null || target.plan.backgroundDownload==null) return false
        // The foreground scheduler counts these mappings in the same two-transfer budget.
        if(store.activeBackgroundDownloads().size>=2) return false
        currentCoroutineContext().ensureActive()
        withContext(NonCancellable) {store.installBackgroundDownload(claim,id(),id(),delegated).also {preparing.add(it.id)}}
        }
        try {
            admission.reserve(mapping.id,NetworkWorkKind.Download,
                if(claim.work.automatic) NetworkWorkPriority.Background else NetworkWorkPriority.Interactive,grant.expiresAt)
            mutex.withLock {
                currentCoroutineContext().ensureActive()
                check(!closed && enabled && store.activeBackgroundDownloads().any {it.mapping==mapping})
                target.requireValid();driver.schedule(store,files,mapping,delegated);preparing.remove(mapping.id);admission.observe(mapping)
            }
        }
        catch(error:Exception) {
            val issue=if(error is CancellationException) null else resourceDownloadFailure(error,claim.work,System.currentTimeMillis()).issue
            withContext(NonCancellable) {mutex.withLock {
                preparing.remove(mapping.id);drain(mapping,issue);driver.reconcile(store,files,preparing,::released);releaseRetired()
            }}
            if(error is CancellationException) throw error
        }
        return true
    }
    suspend fun recover()=mutex.withLock {check(!closed);synchronize()}
    suspend fun disableAndDrain()=withContext(NonCancellable) {mutex.withLock {
        if(!closed) {enabled=false;stopPublications();synchronize(drainAll=true)}
    }}
    suspend fun close()=withContext(NonCancellable) {mutex.withLock {
        if(!closed) {
            closed=true;enabled=false;stopPublications()
            // Account withdrawal retires delegated operations, including already received raw bytes.
            for(snapshot in store.activeBackgroundDownloads()) {
                val work=store.resourceDownloads().firstOrNull {it.work.id==snapshot.mapping.download}?.work
                if(work!=null && !work.terminal && work.control!=ResourceDownloadControl.Cancel)
                    store.controlResourceDownload(work.id,ResourceDownloadControl.Cancel)
            }
            synchronize(drainAll=true)
        }
    }}
    suspend fun observe():Unit=coroutineScope {
        val wake=Channel<Unit>(Channel.CONFLATED)
        val changes=launch {store.resourceDownloadChanges.collect {wake.trySend(Unit)}}
        try {
            while(isActive) {
                val pending=mutex.withLock {
                    if(closed) false else {
                        publications.entries.removeAll {it.value.isCompleted}
                        synchronize()
                        val active=store.activeBackgroundDownloads();val works=store.resourceDownloads().associateBy {it.work.id}
                        if(targets!=null) for(snapshot in active.filter {it.received}) {
                            val work=works[snapshot.mapping.download]?.work ?: continue
                            if(publications.size>=2) break
                            if(snapshot.mapping.id in publications || maxOf(work.retryAt,work.serverRetryAt)>System.currentTimeMillis()) continue
                            val job=launch(start=CoroutineStart.LAZY) {publish(snapshot.mapping)}
                            publications[snapshot.mapping.id]=job;job.invokeOnCompletion {wake.trySend(Unit)};job.start()
                        }
                        active.isNotEmpty()
                    }
                }
                if(pending) withTimeoutOrNull(1000) {wake.receive()} else wake.receive()
            }
        } finally {withContext(NonCancellable) {changes.cancelAndJoin();mutex.withLock {stopPublications()};wake.close()}}
    }
    private suspend fun stopPublications() {
        publications.values.forEach {it.cancel()};publications.values.forEach {it.join()};publications.clear()
    }
    private suspend fun synchronize(drainAll:Boolean=false) {
        val works=store.resourceDownloads().associateBy {it.work.id};val preferences=store.downloadNetworkPreferences()
        val active=store.activeBackgroundDownloads()
        val sources=if(active.isEmpty()) emptyList() else store.backgroundDownloadSources()
        val records=ResourceSystemDownloadJournal.records(context)
        for(row in records.filter {row->row.scope==store.resourceScope && active.none {it.mapping==row.mapping}}) {
            if(row.result==null) admission.beginCancellation(row.mapping.id)
            released(row.mapping,driver.cancelAndDrain(row.mapping))
            files.releaseBackgroundDownloadSource(row.mapping);ResourceSystemDownloadJournal.acknowledge(context,row.mapping)
        }
        for(snapshot in active) {
            val mapping=snapshot.mapping;val row=works[mapping.download]
            if(row!=null && !row.work.automatic) admission.promote(mapping.id,NetworkWorkPriority.Interactive)
            val restricted=row!=null && !snapshot.received &&
                (mapping.constraints.intersecting(preferences.constraints(row.work.automatic))!=mapping.constraints ||
                    row.work.automatic && !preferences.automaticDownloads.allows(row.work.descriptor.contentType,row.work.descriptor.byteCount))
            if(drainAll || row==null || !row.sourceAvailable || row.work.control!=ResourceDownloadControl.Run || restricted) {
                publications.remove(mapping.id)?.cancelAndJoin()
                drain(mapping,ResourceDownloadIssue.Policy.takeIf {restricted})
            } else if(!snapshot.received && mapping.id !in preparing && sources.any {it.mapping==mapping && !it.deleting} &&
                records.any {it.scope==store.resourceScope && it.mapping==mapping && !it.cancelled && it.result==null}) admission.observe(mapping)
        }
        if(!drainAll) driver.restore(store.backgroundDownloadSession())
        driver.reconcile(store,files,preparing,::released);releaseRetired()
    }
    private suspend fun drain(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue?=null) {
        admission.beginCancellation(mapping.id)
        val result=driver.cancelAndDrain(mapping)
        released(mapping,result);preparing.remove(mapping.id)
        store.finishBackgroundDownload(mapping,if(issue==null) result else ResourceBackgroundDownloadResult(mapping.id,mapping.task,null,issue,0,mapping.originDigest))
    }
    private suspend fun releaseRetired() {
        val active=store.activeBackgroundDownloads().map {it.mapping.id}.toSet()
        for(source in store.backgroundDownloadSources().filter {it.mapping.id !in active}) {
            released(source.mapping,driver.cancelAndDrain(source.mapping));files.releaseBackgroundDownloadSource(source.mapping)
        }
    }
    private suspend fun released(mapping:ResourceBackgroundDownloadMapping,result:ResourceBackgroundDownloadResult?)=
        admission.release(mapping.id,result?.status,result?.retryNotBefore,result?.observation)
    private suspend fun publish(mapping:ResourceBackgroundDownloadMapping) {
        val work=store.resourceDownloads().firstOrNull {it.work.id==mapping.download}?.work ?: return
        val reader=MessageOriginalFiles(requireNotNull(targets),store,object:ResourceDownloadFiles {
            override suspend fun <T> withDownloaded(target:MediaDownloadTarget,cacheOnly:Boolean,block:suspend (File)->T):T? {
                files.publishBackgroundDownload(mapping,target)
                return files.withDownloaded(target,cacheOnly=true,block)
            }
        })
        try {
            withTimeout(120_000) {
                // Publication obtains a fresh account authorization after native bytes return.
                // This detached observer must retain the durable download's recovery classification.
                val completed=withContext(NetworkWorkIntent(if(work.automatic) NetworkWorkPriority.Background else NetworkWorkPriority.Interactive,true)+
                    (waiting?.let {ResourceTransferWaitScope(ResourceTransferId(ResourceTransferKind.Download,work.id),it)} ?: kotlin.coroutines.EmptyCoroutineContext)) {
                    reader.withAuthorizedOriginal(mapping.key,cacheOnly=true,message=mapping.message) {read,_->
                        store.completeBackgroundDownload(mapping,read.evidence)
                    }
                }
                if(completed!=true) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
            }
        } catch(error:Exception) {
            if(error is CancellationException && (error !is TimeoutCancellationException || !currentCoroutineContext().isActive)) throw error
            withContext(NonCancellable) {
                val work=store.resourceDownloads().firstOrNull {it.work.id==mapping.download}?.work
                if(work!=null) {
                    val failure=resourceDownloadFailure(error,work,System.currentTimeMillis())
                    store.failReceivedBackgroundDownload(mapping,failure.issue,
                        failure.retryAt.takeIf {failure.issue in setOf(ResourceDownloadIssue.Network,ResourceDownloadIssue.Interrupted)},failure.serverRetryAt)
                }
            }
            if(error is ClientFailure.SignedOut) throw error
        } finally {reader.close()}
    }
    private fun id()=UUID.randomUUID().toString().uppercase()
}
