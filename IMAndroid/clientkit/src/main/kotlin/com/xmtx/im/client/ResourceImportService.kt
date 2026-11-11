package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.util.UUID

/** Run only under the account resource owner. Status lookup is derived from the frozen target identity. */
class ResourceImportService(private val actor: UserId,private val store: ResourceImportJournal,private val control: ResourceImportControl,
    private val waiting:ResourceTransferWaiting?=null,private val now: ()->Long=System::currentTimeMillis) {
    private val activity=Mutex()
    private data class Flight(val job: Job,val cancelling: Boolean)
    suspend fun runForeground(): Unit=activity.withLock { coroutineScope {
        val owner=UUID.randomUUID().toString().uppercase();store.recoverResourceImportClaims(owner)
        val wake=Channel<Unit>(Channel.CONFLATED)
        val observer=launch { store.resourceImportChanges.collect { wake.trySend(Unit) } }
        val flights=mutableMapOf<String,Flight>()
        try {
            while(isActive) {
                flights.entries.removeAll { it.value.job.isCompleted }
                val work=store.resourceImports();val indexed=work.associateBy { it.id }
                flights.forEach { (id,flight) -> indexed[id]?.let { if(it.execution.paused || it.cancellationRequested!=flight.cancelling) flight.job.cancel() } }
                val candidates=work.filter { !it.terminal && !it.execution.paused && !it.execution.attention && it.execution.owner==null && it.execution.attempts<5 && it.id !in flights }
                    .sortedWith(compareBy<ResourceImportWork> { maxOf(it.execution.retryAt,it.execution.serverRetryAt) }.thenBy { it.createdAt }.thenBy { it.id })
                for(value in candidates.filter { maxOf(it.execution.retryAt,it.execution.serverRetryAt)<=now() }) {
                    if(flights.size>=2) break
                    flights[value.id]=Flight(launch { try { perform(value.id,owner) } finally { wake.trySend(Unit) } },value.cancellationRequested)
                }
                val next=if(flights.size>=2) null else candidates.filter { it.id !in flights }.minOfOrNull { maxOf(it.execution.retryAt,it.execution.serverRetryAt) }
                if(next==null) wake.receive() else withTimeoutOrNull((next-now()).coerceIn(1,60000)) { wake.receive() }
            }
        } finally { withContext(NonCancellable) { observer.cancelAndJoin();flights.values.forEach { it.job.cancel() };flights.values.forEach { it.job.join() };wake.close() } }
    } }
    /** Explicit bounded pass, serialized with foreground ownership. */
    suspend fun recoverOnce(): Unit=activity.withLock { coroutineScope {
        val owner=UUID.randomUUID().toString().uppercase();store.recoverResourceImportClaims(owner)
        store.resourceImports().filter { !it.terminal && !it.execution.paused && !it.execution.attention && it.execution.owner==null && it.execution.attempts<5 && maxOf(it.execution.retryAt,it.execution.serverRetryAt)<=now() }
            .sortedWith(compareBy<ResourceImportWork> { it.execution.retryAt }.thenBy { it.createdAt }.thenBy { it.id }).take(2).map { async { perform(it.id,owner) } }.awaitAll()
    } }
    private suspend fun perform(id:String,owner:String)=withContext(waiting?.let {ResourceTransferWaitScope(ResourceTransferId(ResourceTransferKind.ServerImport,id),it)} ?: kotlin.coroutines.EmptyCoroutineContext) {performObserved(id,owner)}
    private suspend fun performObserved(id: String,owner: String) {
        val claim=store.claimResourceImport(id,owner,now()) ?: return
        try {
            val deadline=requireNotNull(claim.work.execution.deadline)
            val remaining=deadline-now()
            if(remaining<=0) { store.failResourceImport(claim,ResourceImportIssue.BudgetExhausted,null);return }
            withTimeout(minOf(remaining,30000)) {
                val locator=claim.work.request.locator(actor)
                // The source may already have changed after a successful import whose response was lost.
                val known=try { control.status(locator) } catch(error: ClientFailure.Http) {
                    if(error.status!=404 || claim.work.status!=null) throw error
                    control.create(claim.work.request)
                }
                known.boundTo(claim.work.request,actor)
                val result=if(claim.work.cancellationRequested && known.state !in setOf(ResourceImportState.Cancelled,ResourceImportState.Failed)) {
                    try { control.cancel(locator) } catch(error: ClientFailure.Http) {
                        if(error.status!=409) throw error
                        // Completed uploads cannot be cancelled. The conflict alone is not evidence:
                        // read the original target again and accept only a verified terminal result.
                        control.status(locator).also { if(!it.state.terminal) throw error }
                    }
                } else known
                result.boundTo(claim.work.request,actor)
                withContext(NonCancellable) { store.finishResourceImport(claim,result,now()) }
            }
        } catch(error: Exception) {
            if(error is CancellationException && (error !is TimeoutCancellationException || !currentCoroutineContext().isActive)) {
                withContext(NonCancellable) { store.failResourceImport(claim,ResourceImportIssue.Unknown,null,cancelled=true) };throw error
            }
            val failure=error as? ClientFailure.Http
            val retryable=if(failure!=null) failure.status in setOf(401,408,429) || failure.status>=500 else error is IOException || error is TimeoutCancellationException
            val timestamp=now();val hint=failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it,timestamp) }.getOrDefault(86400000) } ?: 0
            val server=if(hint>0) later(timestamp,hint) else 0
            val retry=later(maxOf(timestamp,server,claim.work.execution.serverRetryAt),minOf(30000L,1000L shl (claim.work.execution.attempts-1)))
            val issue=when {
                failure?.status in setOf(401,403) || error is ClientFailure.SignedOut -> ResourceImportIssue.AuthorizationUnavailable
                error is ClientFailure.Protocol || error is IllegalArgumentException -> ResourceImportIssue.InvalidResponse
                else -> ResourceImportIssue.Transport
            }
            withContext(NonCancellable) { store.failResourceImport(claim,issue,retry.takeIf { retryable && claim.work.execution.attempts<5 && it<requireNotNull(claim.work.execution.deadline) },server) }
            if(error is ClientFailure.SignedOut) throw error
        }
    }
    private fun later(time: Long,delay: Long)=if(delay>Long.MAX_VALUE-time) Long.MAX_VALUE else time+delay
}
