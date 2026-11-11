package com.xmtx.im.platform

import android.content.Context
import android.os.SystemClock
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** Serializes claim handoff, recovery, user controls and account shutdown around one file owner. */
internal class AccountSystemUploads(context:Context,private val store:SqliteClientStore,
    private val files:ManagedResourceFiles,private val control:ResourceBackgroundUploadControl?,
    private val driver:ResourceSystemUploadDriver,private val admission:AccountSystemTransferAdmission=AccountSystemTransferAdmission(context,store.resourceScope,null)) {
    private val context=context.applicationContext
    private val mutex=Mutex()
    private var enabled=false
    private var closed=false
    private val preparing=mutableSetOf<String>()

    suspend fun enable()=mutex.withLock {check(!closed);enabled=true}
    suspend fun disableAndDrain()=withContext(NonCancellable) {mutex.withLock {
        if(!closed) {enabled=false;synchronize(drain=true)}
    }}
    suspend fun close()=withContext(NonCancellable) {mutex.withLock {
        if(!closed) {enabled=false;synchronize(drain=true);closed=true}
    }}

    suspend fun delegate(claim:ResourceUploadClaim):Boolean {
        val request=claim.work.request
        if(control==null || request.usage !is ResourceUsage.Attachment || request.byteCount>256L*1024*1024) return false
        if(mutex.withLock {closed || !enabled}) return false
        val targets=try {control.backgroundTargets(requireNotNull(claim.work.session),request)}
        catch(error:ClientFailure.Http) {
            // Providers may support foreground PUT without supporting delegated PUT.
            if(error.status==422) return false else throw error
        }
        if(targets.isEmpty()) return false
        val registrations=targets.map {ResourceBackgroundUploadRegistration(id(),id(),it)}.toPersistentList()
        val mappings=mutex.withLock {
            if(closed || !enabled || targets.size>16-store.activeBackgroundUploads().size) return false
            currentCoroutineContext().ensureActive()
            // All siblings retain one durable handoff, but each is scheduled only after its own permit.
            withContext(NonCancellable) {store.installBackgroundUploads(claim,registrations).also {rows->preparing.addAll(rows.map {it.id})}}
        }
        try {
            for((mapping,registration) in mappings.zip(registrations)) {
                admission.reserve(mapping.id,NetworkWorkKind.Upload,currentCoroutineContext()[NetworkWorkIntent]?.priority ?: NetworkWorkPriority.Recovery,registration.target.plan.expiresAt)
                mutex.withLock {
                    currentCoroutineContext().ensureActive()
                    check(!closed && enabled && store.activeBackgroundUploads().any {it==mapping})
                    driver.schedule(store,files,mapping,registration.target);preparing.remove(mapping.id);admission.observe(mapping)
                }
            }
        } catch(error:Exception) {
            // Even an unscheduled sibling must be drained/proven absent before clearing pending.
            withContext(NonCancellable) {mutex.withLock {
                preparing.removeAll(mappings.map {it.id}.toSet());mappings.forEach {drain(it)}
                driver.reconcile(store,files,::released)
            }}
            if(error is CancellationException) throw error
            // The original upload keeps its identity and resumes via authoritative status.
        }
        return true
    }

    /** Called before the foreground engine can reclaim any ordinary work. */
    suspend fun recover()=mutex.withLock {
        check(!closed)
        synchronize()
        driver.restore(store.backgroundUploadSession())
        synchronize()
    }
    suspend fun observe():Unit=coroutineScope {
        val wake=Channel<Unit>(Channel.CONFLATED)
        val changes=launch {store.resourceUploadChanges.collect {wake.trySend(Unit)}}
        try {
            while(isActive) {
                val pending=mutex.withLock {if(closed) false else {synchronize();store.activeBackgroundUploads().isNotEmpty()}}
                // System completions live outside SQLite so they also need a bounded inbox poll.
                if(pending) withTimeoutOrNull(1000) {wake.receive()} else wake.receive()
            }
        } finally {changes.cancel();wake.close()}
    }

    private suspend fun synchronize(drain:Boolean=false) {
        val records=ResourceSystemUploadJournal.records(context).filter {it.scope==store.resourceScope}.associateBy {it.mapping.id}
        val uploads=store.resourceUploads().associateBy {it.id}
        val mappings=store.activeBackgroundUploads()
        val sources=if(mappings.isEmpty()) emptyList() else store.backgroundUploadSources()
        // A durable native row can outlive its SQLite mapping after a crash. Drain before forgetting its permit.
        for(row in records.values.filter {row->mappings.none {it==row.mapping}}) {
            if(row.result==null) admission.beginCancellation(row.mapping.id)
            val result=driver.cancelAndDrain(row.mapping);released(row.mapping,result)
            files.releaseBackgroundUploadSource(row.mapping);ResourceSystemUploadJournal.acknowledge(context,row.mapping)
        }
        for(mapping in mappings) {
            val work=requireNotNull(uploads[mapping.upload]);val row=records[mapping.id]
            val expired=row!=null && row.result==null && (row.boot!=ResourceSystemUploadDriver.boot(context) ||
                SystemClock.elapsedRealtime() !in row.admittedElapsed until row.deadlineElapsed || requireNotNull(row.plan).expiresAt<=System.currentTimeMillis())
            if(drain || row==null && mapping.id !in preparing || row?.cancelled==true || expired || work.cancellationRequested || work.execution.userPaused) drain(mapping)
            else if(row!=null && row.mapping==mapping && row.result==null && mapping.id !in preparing && sources.any {it.mapping==mapping && it.state==BackgroundSourceState.Ready}) admission.observe(mapping)
        }
        driver.reconcile(store,files,::released)
        // Recover a crash after retiring a mapping but before releasing its durable source.
        val active=store.activeBackgroundUploads().map {it.id}.toSet()
        for(source in store.backgroundUploadSources().filter {it.mapping.id !in active}) {
            released(source.mapping,driver.cancelAndDrain(source.mapping))
            files.releaseBackgroundUploadSource(source.mapping)
        }
    }
    private suspend fun drain(mapping:ResourceBackgroundUploadMapping) {
        admission.beginCancellation(mapping.id)
        val result=driver.cancelAndDrain(mapping)
        released(mapping,result);preparing.remove(mapping.id)
        store.completeBackgroundUpload(mapping,result)
        files.releaseBackgroundUploadSource(mapping)
    }
    private suspend fun released(mapping:ResourceBackgroundUploadMapping,result:ResourceBackgroundUploadResult?)=
        admission.release(mapping.id,result?.status,result?.retryNotBefore,result?.observation)
    private fun id()=UUID.randomUUID().toString().uppercase()
}
