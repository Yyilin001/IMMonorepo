package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.util.UUID
import kotlin.math.pow
import kotlin.random.Random

enum class ResourceEngineState { Idle, Running, Failed, Closed }
/** Account-owned flights. Cancelling a UI waiter never cancels the account's actual transfer. */
class ResourceUploadEngine(private val store: ResourceUploadJournal,private val control: ResourceUploadControl,private val bytes: ResourceUploadBytes,
    private val now: ()->Long=System::currentTimeMillis,private val random: ()->Double={ Random.nextDouble() },dispatcher: CoroutineDispatcher=Dispatchers.IO,
    private val delegate: suspend (ResourceUploadClaim)->Boolean={false},private val waiting:ResourceTransferWaiting?=null,diagnostics:NetworkDiagnostics?=null) {
    private val owner=UUID.randomUUID().toString().uppercase()
    private val scope=CoroutineScope(SupervisorJob()+dispatcher+(diagnostics?.let(::NetworkDiagnosticsScope) ?: kotlin.coroutines.EmptyCoroutineContext))
    private val mutex=Mutex();private val flights=mutableMapOf<String,Deferred<ResourceUploadWork>>()
    private val wake=Channel<Unit>(Channel.CONFLATED)
    private var scheduler: Job?=null;private var observer: Job?=null;private var acquired=false
    private val mutableState=MutableStateFlow(ResourceEngineState.Idle)
    val state: StateFlow<ResourceEngineState> = mutableState.asStateFlow()

    suspend fun start(automatic: Boolean=true) = mutex.withLock {
        check(mutableState.value==ResourceEngineState.Idle)
        // A cancelled dispatcher handoff must not abandon an already-acquired file owner.
        withContext(NonCancellable) { bytes.acquire(owner) };acquired=true
        try {
            currentCoroutineContext().ensureActive()
            store.recoverResourceUploadClaims(owner);mutableState.value=ResourceEngineState.Running
            if(automatic) {
                observer=scope.launch { store.resourceUploadChanges.collect { wake.trySend(Unit) } }
                scheduler=scope.launch { try { recoverLoop() } catch(error: CancellationException) { throw error } catch(_: Exception) { mutableState.value=ResourceEngineState.Failed } }
            }
        } catch(error: Throwable) { withContext(NonCancellable) { bytes.release(owner) };acquired=false;throw error }
    }
    suspend fun resume(id: String): ResourceUploadWork = requireNotNull(flight(id,true)).await()
    suspend fun cancel(id: String) {
        requireRunning()
        store.requestResourceUploadCancellation(id)
        mutex.withLock { flights[id] }?.cancelAndJoin();wake.trySend(Unit)
    }
    suspend fun pause(id: String) {
        requireRunning()
        store.controlResourceUpload(id,true)
        mutex.withLock { flights[id] }?.cancelAndJoin();wake.trySend(Unit)
    }
    suspend fun continueUpload(id: String,retry: Boolean=false) { requireRunning();store.controlResourceUpload(id,false,retry);wake.trySend(Unit) }
    private suspend fun requireRunning() = mutex.withLock { check(state.value==ResourceEngineState.Running) }
    suspend fun close() = withContext(NonCancellable) {
        val running=mutex.withLock { mutableState.value=ResourceEngineState.Closed;flights.values.toList() }
        scheduler?.cancelAndJoin();observer?.cancelAndJoin()
        running.forEach { it.cancel() };running.forEach { it.join() }
        mutex.withLock { if(acquired) { bytes.release(owner);acquired=false } }
        scope.cancel();wake.close()
    }
    private suspend fun flight(id: String,requireSlot: Boolean,candidatesObserved:Long=System.nanoTime()): Deferred<ResourceUploadWork>? = mutex.withLock {
        check(mutableState.value==ResourceEngineState.Running)
        flights[id]?.let { return@withLock it }
        if(flights.size>=2) { check(!requireSlot) { "同时执行的资源任务已满" };return@withLock null }
        val task=scope.async(start=CoroutineStart.LAZY) {
            try { perform(id,candidatesObserved) } catch(error: CancellationException) { throw error }
            catch(error: Exception) { mutableState.value=ResourceEngineState.Failed;scheduler?.cancel();throw error }
            finally { withContext(NonCancellable) { mutex.withLock { flights.remove(id) };wake.trySend(Unit) } }
        }
        flights[id]=task;task.start();task
    }
    private suspend fun recoverLoop() {
        while(currentCoroutineContext().isActive && state.value==ResourceEngineState.Running) {
            val active=mutex.withLock { flights.keys.toSet() }
            val candidates=store.resourceUploads().filter { !it.terminal && !it.execution.backgroundPending && !it.execution.attention && !it.execution.userPaused && it.execution.owner==null && it.id !in active }
            val due=candidates.filter { it.execution.retryAt<=now() }.sortedBy { it.execution.retryAt }
            val candidatesObserved=System.nanoTime()
            for(work in due) if(flight(work.id,false,candidatesObserved)==null) break
            val occupied=mutex.withLock { flights.keys.toSet() }
            val next=if(occupied.size>=2) null else candidates.filter { it.id !in occupied }.minOfOrNull { it.execution.retryAt }
            if(next==null) wake.receive() else withTimeoutOrNull((next-now()).coerceIn(1,60000)) { wake.receive() }
        }
    }
    private suspend fun current(id: String) = requireNotNull(store.resourceUpload(id))
    private suspend fun perform(id: String,candidatesObserved:Long): ResourceUploadWork {
        val claim=store.claimResourceUpload(id,owner,now()) ?: return current(id)
        val execution=claim.work.execution
        return measureOperationStep(OperationKind.MediaUpload,
            if(execution.next==ResourceUploadAction.Status || execution.next==ResourceUploadAction.Cancel) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
            execution.attempts,execution.error!=null && execution.attempts>1,candidatesObserved,
            priority=if(execution.error==null) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery,
            observe={store.resourceUpload(id)?.takeIf {it.request==claim.work.request && it.asset==claim.work.asset}?.operationObservation(now())}) {
            try {
                val remaining=requireNotNull(claim.work.execution.deadline)-now()
                if(remaining<=0) { store.failResourceUpload(claim,ResourceUploadError.BudgetExhausted,null);return@measureOperationStep current(id) }
                withTimeout(minOf(remaining,60000)) {
                    val execution=claim.work.execution
                    withContext(NetworkWorkIntent(if(execution.error==null) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery,
                        execution.error!=null && execution.attempts>1)+(waiting?.let {ResourceTransferWaitScope(ResourceTransferId(ResourceTransferKind.Upload,id),it)} ?: kotlin.coroutines.EmptyCoroutineContext)) {execute(claim)}
                }
            } catch(error: Exception) {
                // Delegation atomically relinquishes this claim. Neither cancellation nor a handoff
                // failure may overwrite its system-task journal (or a subsequent foreground claim).
                val owned=withContext(NonCancellable) {current(id).execution.let {it.owner==claim.owner && it.token==claim.token}}
                if(!owned) throw error
                if(error is CancellationException && (error !is TimeoutCancellationException || !currentCoroutineContext().isActive)) {
                    withContext(NonCancellable) { store.failResourceUpload(claim,ResourceUploadError.OutcomeUnknown,null,cancelled=true) };throw error
                }
                val failure=if(error is ProviderDenial) error.failure else error as? ClientFailure.Http
                val retryable=when {
                    error is ProviderDenial && failure?.status in setOf(401,403) -> true
                    failure!=null -> failure.status in setOf(401,408,429) || failure.status>=500
                    else -> error is IOException && error !is ResourceSourceUnavailable || error is TimeoutCancellationException
                }
                val timestamp=now();val hint=failure?.retryAfter?.let { runCatching { retryAfterMilliseconds(it,timestamp) }.getOrDefault(86400000) } ?: 0
                val server=if(hint>0) addTime(timestamp,hint) else 0
                val deadline=requireNotNull(claim.work.execution.deadline)
                val base=maxOf(timestamp,server,claim.work.execution.serverRetryAt)
                val ceiling=minOf(30000.0,500.0*2.0.pow((claim.work.execution.attempts-1).coerceIn(0,16))).toLong()
                val retry=if(retryable && claim.work.execution.attempts<5 && base<deadline) addTime(base,(minOf(ceiling,deadline-base)*random().coerceIn(0.0,1.0)).toLong()).takeIf { it<deadline } else null
                store.failResourceUpload(claim,if(retryable) ResourceUploadError.Transport else ResourceUploadError.NeedsAttention,retry,server)
            }
            return@measureOperationStep current(id)
        }
    }
    private suspend fun execute(claim: ResourceUploadClaim) {
        val work=claim.work
        when(work.execution.next) {
            ResourceUploadAction.Create -> finishSession(claim,control.create(work.request))
            ResourceUploadAction.Status -> finishSession(claim,control.status(requireNotNull(work.session)))
            ResourceUploadAction.Finalize -> finishSession(claim,control.finalize(requireNotNull(work.session)))
            ResourceUploadAction.Cancel -> {
                val session=work.session?.let { control.status(it) } ?: control.create(work.request)
                currentCoroutineContext().ensureActive()
                val result=if(session.state in setOf(ResourceSessionState.Completed,ResourceSessionState.Cancelled,ResourceSessionState.Failed,ResourceSessionState.Expired)) session else control.cancel(session)
                currentCoroutineContext().ensureActive();store.finishResourceUpload(claim,result,ResourceUploadAction.Cancel,now())
            }
            ResourceUploadAction.Upload -> {
                if(delegate(claim)) return
                val session=requireNotNull(work.session);val plan=control.target(session,work.request)
                if(plan==null) {
                    require(ResourceTransferMode.PartPut in work.request.modes)
                    var total=0L;session.parts.forEach { require(it.byteCount<=work.request.byteCount-total);total+=it.byteCount }
                    require(total==work.request.byteCount)
                    store.finishResourceUpload(claim,null,ResourceUploadAction.Finalize,now());return
                }
                require(plan.mode in ResourceUploadClient.supportedModes && plan.mode in work.request.modes)
                if(plan.mode==ResourceTransferMode.Put) require(plan.expectedBytes==work.request.byteCount && (plan.checksum==null || plan.checksum==work.request.checksum))
                else require(plan.range!=null && plan.range.upper<work.request.byteCount)
                if(plan.expiresAt<=now()) throw ResourceTransferFailure()
                try { bytes.transfer(owner,work,plan) } catch(error: ClientFailure.Http) {
                    // A whole-object conflict after a lost reply requires authoritative finalize verification.
                    if(plan.mode!=ResourceTransferMode.Put || error.status!=409) throw ProviderDenial(error)
                }
                currentCoroutineContext().ensureActive()
                store.finishResourceUpload(claim,null,if(plan.mode==ResourceTransferMode.PartPut) ResourceUploadAction.Status else ResourceUploadAction.Finalize,now())
            }
        }
    }
    private suspend fun finishSession(claim: ResourceUploadClaim,session: ResourceUploadSession) {
        currentCoroutineContext().ensureActive()
        val processing=session.resourceState in setOf(ResourceState.Pending,ResourceState.Verifying,ResourceState.Scanning,ResourceState.Processing) && session.state in setOf(ResourceSessionState.Completed,ResourceSessionState.Finalizing)
        if(processing && (claim.work.execution.polls>=60 || session.expiresAt<=now())) {
            store.failResourceUpload(claim,ResourceUploadError.ProcessingBudgetExhausted,null,session.retryNotBefore ?: 0,session=session);return
        }
        val next=if(session.state in setOf(ResourceSessionState.Created,ResourceSessionState.Uploading)) ResourceUploadAction.Upload else ResourceUploadAction.Status
        val delays=longArrayOf(500,500,500,500,750,1000,2000,5000,10000,30000)
        val retry=maxOf(session.retryNotBefore ?: 0,addTime(now(),if(processing) delays[claim.work.execution.polls.coerceIn(0,delays.lastIndex)] else 0))
        store.finishResourceUpload(claim,session,next,retry,processing,!processing && claim.work.execution.error!=null && next==ResourceUploadAction.Upload)
    }
}
private class ProviderDenial(val failure: ClientFailure.Http): Exception("对象传输未确认")
private fun addTime(base: Long,delay: Long)=if(delay>Long.MAX_VALUE-base) Long.MAX_VALUE else base+delay
