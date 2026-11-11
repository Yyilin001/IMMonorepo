package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.flow.*
import java.util.UUID
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

enum class ResourceTransferWaitingReason { Network,NetworkPolicy,TransferSlot,RequestSlot,ServiceCooldown }
data class ResourceTransferAttemptProgress(val attemptId:String,val transferredBytes:Long,val expectedBytes:Long) {
    init {require(uuidId(attemptId)==attemptId && expectedBytes>0 && transferredBytes in 0..expectedBytes)}
}
data class ResourceTransferObservations(
    val waiting:PersistentMap<ResourceTransferId,ResourceTransferWaitingReason> = persistentMapOf(),
    val attempts:PersistentMap<ResourceTransferId,ResourceTransferAttemptProgress> = persistentMapOf())

/** Ephemeral account observation only; it cannot grant a permit or mutate a durable task. */
class ResourceTransferWaiting(private val nanoTime:()->Long=System::nanoTime) {
    private data class Wait(val transfer:ResourceTransferId,val reason:ResourceTransferWaitingReason)
    private val lock=Any();private var closed=false
    private var network:PersistentMap<ResourceTransferId,ResourceTransferWaitingReason> = persistentMapOf()
    private val waits=linkedMapOf<UUID,Wait>()
    private var attempts:PersistentMap<ResourceTransferId,ResourceTransferAttemptProgress> = persistentMapOf()
    private var native:PersistentMap<ResourceTransferId,ResourceTransferAttemptProgress> = persistentMapOf()
    private val lastPulse=mutableMapOf<ResourceTransferId,Long>()
    private val mutable=MutableStateFlow<PersistentMap<ResourceTransferId,ResourceTransferWaitingReason>>(persistentMapOf())
    private val combined=MutableStateFlow(ResourceTransferObservations())
    val state:StateFlow<PersistentMap<ResourceTransferId,ResourceTransferWaitingReason>> = mutable.asStateFlow()
    /** Waiting and attempt facts are published together; consumers never combine mismatched emissions. */
    val snapshots:StateFlow<ResourceTransferObservations> = combined.asStateFlow()
    class Observation internal constructor(private val hub:ResourceTransferWaiting,private val id:UUID) {
        fun update(reason:ResourceTransferWaitingReason)=hub.update(id,reason)
        fun end()=hub.end(id)
    }
    fun nativeProgress(value:PersistentMap<ResourceTransferId,ResourceTransferAttemptProgress>)=synchronized(lock) {
        require(value.size<=64 && value.keys.none {it.kind==ResourceTransferKind.ServerImport})
        if(!closed && value!=native) {native=value;publish()}
    }
    class Attempt internal constructor(private val hub:ResourceTransferWaiting,private val transfer:ResourceTransferId,private val id:String):ResourceTransferByteObserver {
        override fun report(bytes:Long)=hub.report(transfer,id,bytes)
        override fun end()=hub.endAttempt(transfer,id)
    }
    fun begin(transfer:ResourceTransferId,reason:ResourceTransferWaitingReason):Observation?=synchronized(lock) {
        if(closed || waits.size>=512) return null
        val id=UUID.randomUUID();waits[id]=Wait(transfer,reason);publish();Observation(this,id)
    }
    fun beginAttempt(transfer:ResourceTransferId,expectedBytes:Long):Attempt?=synchronized(lock) {
        require(expectedBytes>0 && transfer.kind!=ResourceTransferKind.ServerImport)
        if(closed) return null
        if(transfer in attempts || attempts.size>=4) return null
        val id=UUID.randomUUID().toString().uppercase()
        attempts=attempts.put(transfer,ResourceTransferAttemptProgress(id,0,expectedBytes));lastPulse[transfer]=nanoTime();publish()
        Attempt(this,transfer,id)
    }
    private fun report(transfer:ResourceTransferId,id:String,bytes:Long)=synchronized(lock) {
        val old=attempts[transfer] ?: return
        if(closed || old.attemptId!=id || bytes<=old.transferredBytes || bytes>old.expectedBytes) return
        attempts=attempts.put(transfer,old.copy(transferredBytes=bytes))
        val now=nanoTime()
        // Preserve every monotonic byte fact but limit intermediate UI emissions to ten per second.
        if(old.transferredBytes==0L || bytes==old.expectedBytes || now-(lastPulse[transfer] ?: now)>=100_000_000L) {
            lastPulse[transfer]=now;publish()
        }
    }
    private fun endAttempt(transfer:ResourceTransferId,id:String)=synchronized(lock) {
        if(attempts[transfer]?.attemptId==id) {attempts=attempts.remove(transfer);lastPulse.remove(transfer);publish()}
    }
    private fun update(id:UUID,reason:ResourceTransferWaitingReason)=synchronized(lock) {
        waits[id]?.let {if(it.reason!=reason) {waits[id]=it.copy(reason=reason);publish()}}
    }
    private fun end(id:UUID)=synchronized(lock) {if(waits.remove(id)!=null) publish()}
    fun networkWaiting(value:PersistentMap<ResourceTransferId,ResourceTransferWaitingReason>)=synchronized(lock) {
        require(value.size<=128 && value.values.all {it==ResourceTransferWaitingReason.Network || it==ResourceTransferWaitingReason.NetworkPolicy})
        if(!closed && value!=network) {network=value;publish()}
    }
    private fun rank(reason:ResourceTransferWaitingReason)=when(reason) {
        ResourceTransferWaitingReason.ServiceCooldown->5;ResourceTransferWaitingReason.Network->4
        ResourceTransferWaitingReason.NetworkPolicy->3;ResourceTransferWaitingReason.TransferSlot->2;ResourceTransferWaitingReason.RequestSlot->1
    }
    private fun publish() {
        val reasons=network.builder()
        waits.values.forEach {wait->if(reasons[wait.transfer]?.let {rank(it)>=rank(wait.reason)}!=true) reasons[wait.transfer]=wait.reason}
        val bytes=attempts.builder()
        // Two physical owners for one canonical task are ambiguous: neither choose nor add them.
        native.forEach {(id,sample)->if(id in attempts) bytes.remove(id) else bytes[id]=sample}
        val snapshot=ResourceTransferObservations(reasons.build(),bytes.build())
        combined.value=snapshot
        mutable.value=snapshot.waiting.filterKeys {snapshot.attempts[it]?.transferredBytes?.let {bytes->bytes>0}!=true}.toPersistentMap()
    }
    fun close()=synchronized(lock) {closed=true;waits.clear();native=persistentMapOf();attempts=persistentMapOf();lastPulse.clear();network=persistentMapOf();publish()}
}
class ResourceTransferWaitScope(val transfer:ResourceTransferId,val hub:ResourceTransferWaiting):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<ResourceTransferWaitScope>
    fun begin(reason:ResourceTransferWaitingReason)=hub.begin(transfer,reason)
    fun beginAttempt(expectedBytes:Long)=hub.beginAttempt(transfer,expectedBytes)
}
fun ResourceTransferPage.applyingObservations(snapshot:ResourceTransferObservations)=copy(entries=entries.map {row->
    val acceptsProgress=when(row.id.kind) {
        ResourceTransferKind.Upload->row.phase in setOf(ResourceTransferPhase.Transferring,ResourceTransferPhase.Confirming)
        ResourceTransferKind.Download->row.phase==ResourceTransferPhase.Transferring
        ResourceTransferKind.ServerImport->false
    }
    val attempt=if(acceptsProgress) snapshot.attempts[row.id] else null
    val phase=if(attempt!=null) ResourceTransferPhase.Transferring else row.phase
    val acceptsWait=phase in setOf(ResourceTransferPhase.Queued,ResourceTransferPhase.Preparing,ResourceTransferPhase.Transferring,ResourceTransferPhase.Confirming,ResourceTransferPhase.Verifying)
        && !(row.id.kind==ResourceTransferKind.ServerImport && phase==ResourceTransferPhase.Transferring)
    val waiting=if(acceptsWait && (attempt?.transferredBytes ?: 0)==0L) snapshot.waiting[row.id] else null
    row.copy(phase=phase,waitingReason=waiting,attemptProgress=attempt.takeIf {waiting==null})
}.toPersistentList())
fun ResourceTransferPage.applyingWaiting(waiting:PersistentMap<ResourceTransferId,ResourceTransferWaitingReason>)=
    applyingObservations(ResourceTransferObservations(waiting=waiting))
