package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** An activation owns permits for durable native mappings, including jobs that have not started yet.
 * A receipt alone is not a release: the coordinator must first cancel/drain the physical JobService.
 */
internal class AccountSystemTransferAdmission(context:Context,private val scope:String,
    private val scheduler:AccountWorkScheduler?,private val progress:AccountNativeTransferProgress?=null,private val nanoTime:()->Long=System::nanoTime) {
    private val context=context.applicationContext
    private val initialization=Mutex();private var prepared=false
    private val mutex=Mutex()
    private val cancellationStarted=mutableMapOf<String,Long>()
    private val permits=mutableMapOf<String,AccountWorkScheduler.Permit>()
    private class Waiting(val job:Job,var priority:NetworkWorkPriority) {val demand=ByteTransferDemand(priority)}
    private val waiting=mutableMapOf<String,Waiting>()

    /** Account all durable physical work in both directions before any owner starts new bytes. */
    suspend fun prepare()=initialization.withLock {
        if(prepared || scheduler==null) return@withLock
        val uploads=ResourceSystemUploadJournal.records(context).filter {it.scope==scope}
        val downloads=ResourceSystemDownloadJournal.records(context).filter {it.scope==scope}
        for((id,kind) in uploads.map {it.mapping.id to NetworkWorkKind.Upload}+downloads.map {it.mapping.id to NetworkWorkKind.Download}) {
            // Retain the handle across cancellation at dispatcher handoff. Repeated preparation is idempotent.
            withContext(NonCancellable) {mutex.withLock {
                if(id !in permits) permits[id]=scheduler.adoptExistingByteTransfer(UUID.fromString(id),
                    NetworkWorkContext("mediaProvider",NetworkWorkPriority.Background,kind))
            }}
        }
        prepared=true
    }

    /** No coordinator lifecycle mutex may be held while this waits. */
    suspend fun reserve(id:String,kind:NetworkWorkKind,priority:NetworkWorkPriority,expiresAt:Long)=coroutineScope {
        prepare()
        val scheduler=this@AccountSystemTransferAdmission.scheduler ?: return@coroutineScope
        val job=currentCoroutineContext().job
        val pending=Waiting(job,priority)
        mutex.withLock {check(id !in permits && id !in waiting);waiting[id]=pending}
        var acquired:AccountWorkScheduler.Permit?=null
        try {
            val duration=minOf(15_000,expiresAt-System.currentTimeMillis())
            if(duration<=0) throw ResourceTransferFailure()
            // The handle lives outside withTimeout so prompt cancellation cannot orphan a grant.
            withTimeout(duration) {withContext(pending.demand) {acquired=scheduler.acquire(NetworkWorkContext("mediaProvider",priority,kind,isRetry=currentCoroutineContext()[NetworkWorkIntent]?.isRetry ?: false))}}
            currentCoroutineContext().ensureActive()
            mutex.withLock {
                check(waiting[id]===pending)
                val value=requireNotNull(acquired)
                permits[id]=if(kind==NetworkWorkKind.Download) scheduler.promoteDownloadPermit(value,pending.priority) ?: value else value
                acquired=null
            }
        } finally {withContext(NonCancellable) {
            mutex.withLock {if(waiting[id]===pending) waiting.remove(id)}
            acquired?.let {scheduler.release(it)}
        }}
    }

    suspend fun promote(id:String,priority:NetworkWorkPriority) {
        val scheduler=scheduler ?: return
        mutex.withLock {
            waiting[id]?.let {it.priority=minOf(it.priority,priority);it.demand.promote(priority)}
            permits[id]?.let {scheduler.promoteDownloadPermit(it,priority)?.let {promoted->permits[id]=promoted}}
        }
    }

    fun observe(mapping:ResourceBackgroundUploadMapping)=progress?.bind(mapping)
    fun observe(mapping:ResourceBackgroundDownloadMapping)=progress?.bind(mapping)

    suspend fun beginCancellation(id:String)=mutex.withLock {
        if(id in permits && id !in cancellationStarted) cancellationStarted[id]=nanoTime()
    }

    /** Called only after physical drain, or before any native task could have been installed. */
    suspend fun release(id:String,status:Int?=null,retryNotBefore:Long?=null,observation:ResourceBackgroundTransferObservation?=null)=withContext(NonCancellable) {
        progress?.retire(id)
        val scheduler=scheduler ?: return@withContext
        val pending=mutex.withLock {waiting[id]?.job}
        pending?.cancelAndJoin()
        if(status in setOf(429,503) && retryNotBefore!=null)
            scheduler.coolDown("mediaProvider",(retryNotBefore-System.currentTimeMillis()).coerceIn(0,86_400_000))
        val (permit,started)=mutex.withLock {permits.remove(id) to cancellationStarted.remove(id)}
        if(permit!=null && scheduler.release(permit)) {
            val elapsed=started?.let {(nanoTime()-it).coerceAtLeast(0)}
            scheduler.transferDiagnostics.record(ResourceBackgroundTransferMetric.from(observation,elapsed))
        }
    }
}
