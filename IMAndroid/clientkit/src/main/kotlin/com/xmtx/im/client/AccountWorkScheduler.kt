package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Scheduling facts carry no request, credential, file handle, or durable business claim. */
enum class NetworkWorkPriority { Critical, Interactive, Recovery, Background }
enum class NetworkWorkKind { Ordinary, Authentication, Upload, Download;
    internal val bytes get()=this==Upload || this==Download
}
data class NetworkWorkContext(val service:String,val priority:NetworkWorkPriority=NetworkWorkPriority.Interactive,
    val kind:NetworkWorkKind=NetworkWorkKind.Ordinary,val orderingKey:String?=null,val isRetry:Boolean=false) {
    internal fun promoting(priority:NetworkWorkPriority)=copy(priority=minOf(this.priority,priority))
}

/** Leaf transports consume this metadata; domain steps must not acquire a parent permit. */
class NetworkWorkScope(val scheduler:AccountWorkScheduler,val work:NetworkWorkContext):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<NetworkWorkScope>
}

/** Shared download consumers may monotonically raise queued demand; this does not alter OS network policy. */
class ByteTransferDemand(priority:NetworkWorkPriority):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<ByteTransferDemand>
    private val lock=Any()
    private var current=priority
    private val observers=mutableMapOf<UUID,(NetworkWorkPriority)->Unit>()
    fun promote(priority:NetworkWorkPriority) {
        val callbacks=synchronized(lock) {
            if(priority>=current) return
            current=priority;observers.values.toList()
        }
        callbacks.forEach {it(priority)}
    }
    internal fun observe(id:UUID,callback:(NetworkWorkPriority)->Unit):NetworkWorkPriority=synchronized(lock) {
        observers[id]=callback;current
    }
    internal fun remove(id:UUID) {synchronized(lock) {observers.remove(id)}}
    internal val observerCount get()=synchronized(lock) {observers.size}
}

/** One activation's admission domain. Callers cancel and drain transports before closing it. */
class AccountWorkScheduler(
    private val configuration:Configuration=Configuration(),
    private val nowMillis:()->Long={System.nanoTime()/1_000_000},
    dispatcher:CoroutineDispatcher=Dispatchers.Default,
) {
    val networkDiagnostics=NetworkDiagnostics()
    val transferDiagnostics get()=networkDiagnostics
    data class Configuration(val ordinaryLimit:Int=6,val serviceLimit:Int=4,val authenticationLimit:Int=1,
        val byteTransferLimit:Int=4,val uploadTransferLimit:Int=2,val downloadTransferLimit:Int=2,
        val interactiveByteReserve:Int=1,val byteTransferWaiterLimit:Int=128,val byteTransferAgingMillis:Long=15_000,
        val waiterLimit:Int=256,val controlWaiterLimit:Int=64) {
        init {
            require(ordinaryLimit>0 && serviceLimit>0 && authenticationLimit>0 && byteTransferLimit>0)
            require(uploadTransferLimit>0 && downloadTransferLimit>0 && interactiveByteReserve>=0)
            require(waiterLimit>=0 && controlWaiterLimit>=0 && byteTransferWaiterLimit>=0 && byteTransferAgingMillis>0)
        }
    }
    enum class Rejection { Closed, Overloaded, DeadlineExceeded, InvalidAdoption }
    class AdmissionException(val reason:Rejection):Exception("Network admission: $reason")
    /** No public constructor or copy operation; identity is scoped to this scheduler. */
    class Permit private constructor(internal val owner:UUID,internal val id:UUID,val context:NetworkWorkContext) {
        override fun equals(other:Any?)=other is Permit && owner==other.owner && id==other.id
        override fun hashCode()=31*owner.hashCode()+id.hashCode()
        companion object {internal fun create(owner:UUID,id:UUID,context:NetworkWorkContext)=Permit(owner,id,context)}
    }
    data class Snapshot(val active:Int,val waiting:Int,val closed:Boolean,val activeUploads:Int,val activeDownloads:Int,
        val waitingByteTransfers:Int,val activeBackgroundTransfers:Int)
    private data class Waiter(val id:UUID,var context:NetworkWorkContext,val enqueuedAt:Long,val result:CompletableDeferred<Permit>,val observation:ResourceTransferWaiting.Observation?)
    private class Service(var lastRefill:Long,var tokens:Int=5,var cooldownUntil:Long=Long.MIN_VALUE) {
        fun refill(now:Long) {
            if(now>=lastRefill && now-lastRefill>=2000) {
                val intervals=(now-lastRefill)/2000
                tokens=minOf(5,tokens+minOf(5L,intervals).toInt());lastRefill+=intervals*2000
            }
        }
    }
    private val identity=UUID.randomUUID()
    private val mutex=Mutex()
    private val scope=CoroutineScope(SupervisorJob()+dispatcher)
    private val active=linkedMapOf<UUID,Permit>()
    private val adopted=mutableMapOf<UUID,UUID>()
    private val waiting=mutableListOf<Waiter>()
    private val services=mutableMapOf<String,Service>()
    private val degradedServices=mutableSetOf<String>()
    private val qualityObserver=NetworkQualityObserver()
    private var degraded=false
    private var closed=false
    private var wake:Job?=null
    private var drain=CompletableDeferred<Unit>().also {it.complete(Unit)}
    private val wheel=listOf(NetworkWorkPriority.Critical,NetworkWorkPriority.Interactive,NetworkWorkPriority.Critical,
        NetworkWorkPriority.Interactive,NetworkWorkPriority.Recovery,NetworkWorkPriority.Critical,
        NetworkWorkPriority.Interactive,NetworkWorkPriority.Background,NetworkWorkPriority.Critical,
        NetworkWorkPriority.Interactive,NetworkWorkPriority.Recovery)
    private var cursor=0

    suspend fun snapshot():Snapshot=mutex.withLock {
        Snapshot(active.size,waiting.size,closed,active.values.count {it.context.kind==NetworkWorkKind.Upload},
            active.values.count {it.context.kind==NetworkWorkKind.Download},waiting.count {it.context.kind.bytes},
            active.values.count {it.context.kind.bytes && it.context.priority==NetworkWorkPriority.Background})
    }
    /** Restored physical tasks may exceed today's limits. Adopt all of them before admitting new work. */
    suspend fun adoptExistingByteTransfer(id:UUID,context:NetworkWorkContext):Permit=mutex.withLock {
        if(closed) reject(Rejection.Closed)
        if(!context.kind.bytes) reject(Rejection.InvalidAdoption)
        adopted[id]?.let {key->active[key]?.let {permit->
            if(permit.context!=context) reject(Rejection.InvalidAdoption)
            return@withLock permit
        }}
        registerService(context)
        install(UUID.randomUUID(),context).also {adopted[id]=it.id}
    }
    suspend fun promoteDownloadPermit(permit:Permit,priority:NetworkWorkPriority):Permit?=mutex.withLock {
        val current=active[permit.id]
        if(closed || permit.owner!=identity || current?.context?.kind!=NetworkWorkKind.Download) return@withLock null
        Permit.create(identity,current.id,current.context.promoting(priority)).also {active[it.id]=it;dispatch()}
    }
    suspend fun setDegraded(value:Boolean)=mutex.withLock {degraded=value;dispatch()}
    suspend fun setServiceDegraded(service:String,value:Boolean)=mutex.withLock {
        if(value && degradedServices.size<64) degradedServices.add(service)
        if(!value) degradedServices.remove(service)
        dispatch()
    }
    suspend fun serviceQuality(service:String)=mutex.withLock {qualityObserver.quality(service)}
    /** Observation and admission update share one lock, so concurrent completions cannot reorder quality. */
    internal suspend fun recordQuality(sample:NetworkQualityObserver.Sample,service:String)=mutex.withLock {
        if(closed) return@withLock
        val quality=qualityObserver.record(sample,service,nowMillis())
        if(quality==NetworkQualityObserver.Quality.Degraded) {
            if(degradedServices.size<64) degradedServices.add(service)
        } else degradedServices.remove(service)
        dispatch()
    }
    suspend fun coolDown(service:String,millis:Long)=mutex.withLock {
        val state=services[service]
        if(!closed && millis>0 && state!=null) {state.cooldownUntil=maxOf(state.cooldownUntil,addTime(nowMillis(),millis));dispatch()}
    }
    /** Deadline uses the injected monotonic clock, never wall time or a server timestamp. */
    suspend fun acquire(context:NetworkWorkContext,deadlineMillis:Long?=null):Permit {
        currentCoroutineContext().ensureActive()
        val id=UUID.randomUUID();val result=CompletableDeferred<Permit>();var delivered=false
        val transfer=currentCoroutineContext()[ResourceTransferWaitScope]
        var observation:ResourceTransferWaiting.Observation?=null
        val demand=currentCoroutineContext()[ByteTransferDemand]?.takeIf {context.kind==NetworkWorkKind.Download}
        try {
            mutex.withLock {
                if(closed) reject(Rejection.Closed)
                if(deadlineMillis!=null && deadlineMillis<=nowMillis()) reject(Rejection.DeadlineExceeded)
                val priority=demand?.observe(id) {value->scope.launch {mutex.withLock {
                    if(!closed) waiting.firstOrNull {it.id==id}?.let {it.context=it.context.promoting(value);dispatch()}
                }}}
                val effective=priority?.let {context.promoting(it)} ?: context
                registerService(effective);dispatch()
                if(canAdmitDirectly(effective) && eligible(effective)) result.complete(grant(id,effective))
                else {
                    if(!hasWaitingCapacity(effective)) reject(Rejection.Overloaded)
                    observation=transfer?.begin(waitingReason(effective))
                    waiting.add(Waiter(id,effective,nowMillis(),result,observation));dispatch()
                }
            }
            val permit=if(deadlineMillis==null) result.await() else {
                val remaining=deadlineMillis-nowMillis()
                if(remaining<=0) reject(Rejection.DeadlineExceeded)
                withTimeoutOrNull(remaining) {result.await()} ?: reject(Rejection.DeadlineExceeded)
            }
            currentCoroutineContext().ensureActive()
            if(deadlineMillis!=null && deadlineMillis<=nowMillis()) reject(Rejection.DeadlineExceeded)
            delivered=true
            return permit
        } finally {
            observation?.end();demand?.remove(id)
            // await has prompt cancellation: a granted permit may never have reached its caller.
            if(!delivered) withContext(NonCancellable) {mutex.withLock {
                waiting.removeAll {it.id==id};active[id]?.let {releaseLocked(it)};dispatch()
            }}
        }
    }
    /** operation must not return until the actual network callback / physical I/O has drained. */
    suspend fun <T> withPermit(context:NetworkWorkContext,deadlineMillis:Long?=null,operation:suspend (Permit)->T):T {
        val permit=acquire(context,deadlineMillis)
        try {return operation(permit)} finally {withContext(NonCancellable) {release(permit)}}
    }
    suspend fun release(permit:Permit):Boolean=mutex.withLock {releaseLocked(permit).also {if(it) dispatch()}}
    suspend fun beginClose()=mutex.withLock {
        closed=true;wake?.cancel();wake=null
        val pending=waiting.toList();waiting.clear()
        pending.forEach {it.observation?.end();it.result.completeExceptionally(AdmissionException(Rejection.Closed))}
        scope.cancel()
    }
    suspend fun closeAndDrain() {beginClose();val completion=mutex.withLock {drain};completion.await();transferDiagnostics.close()}
    private fun reject(reason:Rejection):Nothing=throw AdmissionException(reason)
    private fun registerService(context:NetworkWorkContext) {
        if(context.kind!=NetworkWorkKind.Authentication && context.service !in services) {
            if(services.size>=64) reject(Rejection.Overloaded)
            services[context.service]=Service(nowMillis())
        }
    }
    private fun releaseLocked(permit:Permit):Boolean {
        if(permit.owner!=identity || active.remove(permit.id)==null) return false
        adopted.entries.removeAll {it.value==permit.id}
        if(active.isEmpty()) drain.complete(Unit)
        return true
    }
    private fun install(id:UUID,context:NetworkWorkContext):Permit {
        if(active.isEmpty()) drain=CompletableDeferred()
        return Permit.create(identity,id,context).also {active[id]=it}
    }
    private fun grant(id:UUID,context:NetworkWorkContext):Permit {
        if(context.isRetry && context.kind!=NetworkWorkKind.Authentication) {
            val service=services.getValue(context.service);service.refill(nowMillis());check(service.tokens>0);service.tokens--
        }
        return install(id,context)
    }
    private fun notBefore(context:NetworkWorkContext):Long {
        val now=nowMillis()
        if(context.kind==NetworkWorkKind.Authentication) return now
        val state=services[context.service] ?: return now
        state.refill(now)
        return maxOf(state.cooldownUntil,if(context.isRetry && state.tokens==0) addTime(state.lastRefill,2000) else now)
    }
    private fun eligible(context:NetworkWorkContext):Boolean {
        if(notBefore(context)>nowMillis()) return false
        if(context.orderingKey!=null && active.values.any {it.context.orderingKey==context.orderingKey}) return false
        val same=active.values.filter {it.context.kind==context.kind}
        val serviceDegraded=context.service in degradedServices
        when(context.kind) {
            NetworkWorkKind.Authentication->return same.size<configuration.authenticationLimit
            NetworkWorkKind.Ordinary->return same.size<(if(degraded) minOf(3,configuration.ordinaryLimit) else configuration.ordinaryLimit) &&
                same.count {it.context.service==context.service}<(if(serviceDegraded) minOf(3,configuration.serviceLimit) else configuration.serviceLimit)
            else->{
                val bytes=active.values.filter {it.context.kind.bytes}
                val total=if(degraded || serviceDegraded) minOf(1,configuration.byteTransferLimit) else configuration.byteTransferLimit
                val direction=if(context.kind==NetworkWorkKind.Upload) configuration.uploadTransferLimit else configuration.downloadTransferLimit
                if(bytes.size>=total || same.size>=direction) return false
                if(bytes.count {it.context.kind==NetworkWorkKind.Upload}>configuration.uploadTransferLimit ||
                    bytes.count {it.context.kind==NetworkWorkKind.Download}>configuration.downloadTransferLimit) return false
                if(context.priority==NetworkWorkPriority.Background) {
                    val totalBackground=maxOf(1,total-minOf(configuration.interactiveByteReserve,total-1))
                    val directionBackground=maxOf(1,direction-minOf(configuration.interactiveByteReserve,direction-1))
                    return bytes.count {it.context.priority==NetworkWorkPriority.Background}<totalBackground &&
                        same.count {it.context.priority==NetworkWorkPriority.Background}<directionBackground
                }
                return true
            }
        }
    }
    private fun hasWaitingCapacity(context:NetworkWorkContext):Boolean=when(context.kind) {
        NetworkWorkKind.Authentication->waiting.count {it.context.kind==NetworkWorkKind.Authentication}<configuration.controlWaiterLimit
        NetworkWorkKind.Ordinary->waiting.count {it.context.kind==NetworkWorkKind.Ordinary}<configuration.waiterLimit
        else->waiting.count {it.context.kind.bytes}<configuration.byteTransferWaiterLimit
    }
    private fun canAdmitDirectly(context:NetworkWorkContext):Boolean {
        if(context.orderingKey!=null && waiting.any {it.context.orderingKey==context.orderingKey}) return false
        return waiting.none {(it.context.kind==context.kind || it.context.kind.bytes && context.kind.bytes) && eligible(it.context)}
    }
    private fun firstForKey(index:Int):Boolean {
        val key=waiting[index].context.orderingKey ?: return true
        return (0 until index).none {waiting[it].context.orderingKey==key}
    }
    private fun waitingReason(context:NetworkWorkContext)=if(notBefore(context)>nowMillis()) ResourceTransferWaitingReason.ServiceCooldown
        else if(context.kind.bytes) ResourceTransferWaitingReason.TransferSlot else ResourceTransferWaitingReason.RequestSlot
    private fun dispatch() {
        if(closed) return
        waiting.forEach {it.observation?.update(waitingReason(it.context))}
        while(true) {
            var selected=waiting.indices.firstOrNull {i->val w=waiting[i]
                w.context.kind.bytes && nowMillis()-w.enqueuedAt>=configuration.byteTransferAgingMillis && eligible(w.context) && firstForKey(i)}
            if(selected==null) for(offset in wheel.indices) {
                val position=(cursor+offset)%wheel.size
                val match=waiting.indices.firstOrNull {i->waiting[i].context.priority==wheel[position] && eligible(waiting[i].context) && firstForKey(i)}
                if(match!=null) {selected=match;cursor=(position+1)%wheel.size;break}
            }
            if(selected==null) {scheduleWake();return}
            val waiter=waiting.removeAt(selected);waiter.observation?.end();waiter.result.complete(grant(waiter.id,waiter.context))
        }
    }
    private fun scheduleWake() {
        wake?.cancel();wake=null
        val now=nowMillis();val due=waiting.map {notBefore(it.context)}.filter {it>now}.minOrNull() ?: return
        wake=scope.launch {delay(maxOf(1,due-now));mutex.withLock {dispatch()}}
    }
    private fun addTime(now:Long,duration:Long)=if(now>Long.MAX_VALUE-duration) Long.MAX_VALUE else now+duration
}
