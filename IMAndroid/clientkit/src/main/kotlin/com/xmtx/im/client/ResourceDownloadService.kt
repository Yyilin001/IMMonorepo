package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentMap
import kotlinx.collections.immutable.persistentMapOf
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.util.UUID

/** Account-owned foreground scheduler. A stopped generation drains before another can recover its claims. */
class ResourceDownloadService(private val store:ResourceDownloadJournal,private val now:()->Long=System::currentTimeMillis,
    private val automaticForeground:()->Boolean={true},private val automaticNetwork:suspend ()->Boolean={false},
    private val nanoTime:()->Long=System::nanoTime,
    private val waiting:ResourceTransferWaiting?=null,
    private val automaticWaiting:()->ResourceTransferWaitingReason={ResourceTransferWaitingReason.NetworkPolicy},
    private val download:suspend (ResourceDownloadClaim,suspend (MessageResourceRead)->Unit)->Unit) {
    private val activity=Mutex()
    suspend fun runForeground():Unit=activity.withLock {coroutineScope {
        val owner=UUID.randomUUID().toString().uppercase();store.recoverResourceDownloads(owner,now())
        val wake=Channel<Unit>(Channel.CONFLATED);val flights=mutableMapOf<String,Job>();val waitingSince=mutableMapOf<String,Long>()
        val observer=launch {store.resourceDownloadChanges.collect {wake.trySend(Unit)}}
        try {
            while(isActive) {
                flights.entries.removeAll {it.value.isCompleted}
                val automaticActive=automaticForeground()
                val automaticAllowed=automaticActive && automaticNetwork()
                if(automaticActive) store.prepareAutomaticDownloads(now(),automaticAllowed)
                val rows=store.resourceDownloads();val indexed=rows.associateBy {it.work.id}
                val networkWait=if(automaticActive && !automaticAllowed) automaticWaiting() else null
                waiting?.networkWaiting(rows.filter {row->val w=row.work;networkWait!=null && row.sourceAvailable && w.automatic && w.requested && w.control==ResourceDownloadControl.Run && w.phase==ResourceDownloadPhase.Pending && !w.backgroundPending && w.attempts<5 && maxOf(w.retryAt,w.serverRetryAt)<=now()}.associate {ResourceTransferId(ResourceTransferKind.Download,it.work.id) to requireNotNull(networkWait)}.toPersistentMap())
                val delegated=rows.filter {it.work.backgroundPending && it.work.id !in flights}
                flights.forEach {(id,job)->val value=indexed[id];if(value==null || !value.sourceAvailable || value.work.control!=ResourceDownloadControl.Run) job.cancel()}
                val eligible=rows.filter {row->val w=row.work;w.phase==ResourceDownloadPhase.Pending && !w.backgroundPending && w.control==ResourceDownloadControl.Run && w.requested && w.attempts<5 && w.id !in flights && (!w.automatic || automaticAllowed)}
                val monotonic=nanoTime();val wall=now()
                waitingSince.keys.retainAll(eligible.filter {maxOf(it.work.retryAt,it.work.serverRetryAt)<=wall}.map {it.work.id}.toSet())
                eligible.filter {maxOf(it.work.retryAt,it.work.serverRetryAt)<=wall}.forEach {waitingSince.putIfAbsent(it.work.id,monotonic)}
                val candidates=eligible.sortedWith(compareBy<ResourceDownloadSnapshot> {
                    resourceDownloadSchedulingPriority(it.work,waitingSince[it.work.id]?.let {start->monotonic-start} ?: 0)
                }.thenBy {maxOf(it.work.retryAt,it.work.serverRetryAt)}.thenBy {it.work.createdAt}.thenBy {it.work.id})
                for(row in candidates.filter {maxOf(it.work.retryAt,it.work.serverRetryAt)<=now()}) {
                    if(flights.size+delegated.size>=2) break
                    if(row.work.automatic && (delegated.any {it.work.automatic} || flights.keys.any {indexed[it]?.work?.automatic==true})) continue
                    val id=row.work.id;val job=launch(start=CoroutineStart.LAZY) {perform(id,owner)}
                    flights[id]=job;job.invokeOnCompletion {wake.trySend(Unit)};job.start()
                }
                val next=if(flights.size+delegated.size>=2) null else candidates.filter {it.work.id !in flights && (!it.work.automatic || delegated.none {it.work.automatic} && flights.keys.none {id->indexed[id]?.work?.automatic==true})}.minOfOrNull {maxOf(it.work.retryAt,it.work.serverRetryAt)}
                withTimeoutOrNull(if(next==null) 5000 else (next-now()).coerceIn(1,5000)) {wake.receive()}
            }
        } finally {withContext(NonCancellable) {observer.cancelAndJoin();flights.values.forEach {it.cancel()};flights.values.forEach {it.join()};waiting?.networkWaiting(persistentMapOf());wake.close()}}
    }}
    private suspend fun perform(id:String,owner:String) {
        val claim=store.claimResourceDownload(id,owner,now()) ?: return
        var released=false
        try {
            // Network targets expire sooner; this also bounds a misbehaving transport implementation.
            withTimeout(15*60_000L) {
                // Like Swift performResume, all durable download claims are recovery work, even
                // when a user resumed a round and reset its bounded counter to zero.
                val intent=NetworkWorkIntent(if(claim.work.automatic) NetworkWorkPriority.Background else NetworkWorkPriority.Interactive,true)
                withContext(intent+(waiting?.let {ResourceTransferWaitScope(ResourceTransferId(ResourceTransferKind.Download,id),it)} ?: kotlin.coroutines.EmptyCoroutineContext)+(if(claim.work.automatic) AutomaticResourceDownload(claim.work.descriptor) else kotlin.coroutines.EmptyCoroutineContext)) {
                    download(claim) {read->store.completeResourceDownload(claim,read,now())}
                }
            }
        } catch(error:Exception) {
            val interrupted=error is CancellationException && (error !is TimeoutCancellationException || !currentCoroutineContext().isActive)
            val failure=resourceDownloadFailure(error,claim.work,now())
            withContext(NonCancellable) {store.releaseResourceDownload(claim,failure.issue,failure.retryAt,failure.serverRetryAt,interrupted,now());released=true}
            if(interrupted || error is ClientFailure.SignedOut) throw error
        } finally {
            // Completed/stale claims are no-ops. A callback that returned without publishing cannot finish a task.
            if(!released) withContext(NonCancellable) {store.releaseResourceDownload(claim,ResourceDownloadIssue.Interrupted,null,0,true,now())}
        }
    }
}

data class ResourceDownloadFailure(val issue:ResourceDownloadIssue,val retryAt:Long?,val serverRetryAt:Long)
fun resourceDownloadFailure(error:Exception,work:ResourceDownloadWork,now:Long,randomUnit:()->Double={kotlin.random.Random.nextDouble()}):ResourceDownloadFailure {
    val read=error as? MediaReadFailure;val http=error as? ClientFailure.Http
    val issue=when {
        error is ResourceDownloadPolicyRestricted -> ResourceDownloadIssue.Policy
        error is ClientFailure.SignedOut || read?.reason==MediaReadFailureReason.AuthorizationUnavailable || http?.status==401 -> ResourceDownloadIssue.Authorization
        read?.reason==MediaReadFailureReason.Denied || error is ResourceCatalogConflict -> ResourceDownloadIssue.Unavailable
        read?.reason in setOf(MediaReadFailureReason.Integrity,MediaReadFailureReason.InvalidResponse) || error is MediaFileFailure || error is ClientFailure.Protocol || error is IllegalArgumentException -> ResourceDownloadIssue.Integrity
        read?.reason in setOf(MediaReadFailureReason.Expired,MediaReadFailureReason.SourceChanged) || error is CancellationException -> ResourceDownloadIssue.Interrupted
        error is ResourceSourceUnavailable -> ResourceDownloadIssue.Storage
        error is IOException || read?.reason==MediaReadFailureReason.Unavailable || http!=null -> ResourceDownloadIssue.Network
        else -> ResourceDownloadIssue.Storage
    }
    val retryable=error is IOException && error !is ResourceSourceUnavailable || error is TimeoutCancellationException || read?.reason in setOf(MediaReadFailureReason.Expired,MediaReadFailureReason.SourceChanged) ||
        read?.reason==MediaReadFailureReason.Unavailable && (read.status==429 || (read.status ?: 0)>=500) || http?.status in setOf(408,429) || (http?.status ?: 0)>=500
    fun later(value:Long,delay:Long)=if(delay>Long.MAX_VALUE-value) Long.MAX_VALUE else value+delay
    val hint=(read?.retryAfter ?: http?.retryAfter)?.let {runCatching {retryAfterMilliseconds(it,now)}.getOrDefault(86_400_000)} ?: 0
    val floor=maxOf(work.serverRetryAt,if(hint>0) later(now,hint) else 0)
    val delay=minOf(30_000L,1000L shl (work.attempts-1).coerceAtLeast(0))
    val retry=if(work.automatic && retryable) maxOf(floor,later(now,(delay*(0.75+0.5*randomUnit().coerceIn(0.0,1.0))).toLong()))
        else later(maxOf(now,floor),delay)
    return ResourceDownloadFailure(issue,retry.takeIf {retryable && work.attempts<5},floor)
}

/** A waiting automatic transfer ages ahead after 15 seconds; its one-slot ceiling still applies. */
internal fun resourceDownloadSchedulingPriority(work:ResourceDownloadWork,waitingNanos:Long)=
    if(work.automatic && waitingNanos>=15_000_000_000L) -1 else if(work.automatic) 1 else 0
