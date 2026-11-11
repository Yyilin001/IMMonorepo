package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

/** Ephemeral process-local counters. No account owner, request capability, path or byte buffer. */
internal data class SystemTransferProgressKey(val scope:String,val kind:ResourceTransferKind,val mapping:String,val task:String)
internal data class NativeTransferProgressBinding(val key:SystemTransferProgressKey,val transfer:ResourceTransferId,val expectedBytes:Long,val expiresAt:Long)

internal class SystemTransferProgressRegistry(private val nanoTime:()->Long=System::nanoTime) {
    private class Flight(val token:UUID,var sample:ResourceTransferAttemptProgress,var pulse:Long)
    private val lock=Any();private val flights=mutableMapOf<SystemTransferProgressKey,Flight>()
    private val mutable=MutableStateFlow<PersistentMap<SystemTransferProgressKey,ResourceTransferAttemptProgress>>(persistentMapOf())
    val samples:StateFlow<PersistentMap<SystemTransferProgressKey,ResourceTransferAttemptProgress>> = mutable.asStateFlow()
    fun begin(key:SystemTransferProgressKey,expectedBytes:Long):ResourceTransferByteObserver?=synchronized(lock) {
        if(expectedBytes<=0 || key.kind==ResourceTransferKind.ServerImport || key in flights || flights.size>=64) return null
        val token=UUID.randomUUID();val sample=ResourceTransferAttemptProgress(key.mapping,0,expectedBytes)
        flights[key]=Flight(token,sample,nanoTime());mutable.value=mutable.value.put(key,sample)
        object:ResourceTransferByteObserver {
            override fun report(bytes:Long)=synchronized(lock) {
                val current=flights[key] ?: return
                if(current.token!=token || bytes<=current.sample.transferredBytes || bytes>current.sample.expectedBytes) return
                val first=current.sample.transferredBytes==0L
                current.sample=current.sample.copy(transferredBytes=bytes)
                val now=nanoTime()
                if(first || bytes==expectedBytes || now-current.pulse>=100_000_000L) {
                    current.pulse=now;mutable.value=mutable.value.put(key,current.sample)
                }
            }
            override fun end()=synchronized(lock) {
                if(flights[key]?.token==token) {flights.remove(key);mutable.value=mutable.value.remove(key)}
            }
        }
    }
}
internal val systemTransferProgress=SystemTransferProgressRegistry()

/** Bind only after the account has adopted the exact mapping and owns its durable source. */
internal class AccountNativeTransferProgress(private val scope:String,private val hub:ResourceTransferWaiting,
    private val registry:SystemTransferProgressRegistry=systemTransferProgress,private val now:()->Long=System::currentTimeMillis) {
    private val lock=Any();private var closed=false
    private val bindingCount=MutableStateFlow(0)
    private var bindings:PersistentMap<SystemTransferProgressKey,NativeTransferProgressBinding> = persistentMapOf()
    fun bind(mapping:ResourceBackgroundUploadMapping)=bind(NativeTransferProgressBinding(
        SystemTransferProgressKey(scope,ResourceTransferKind.Upload,mapping.id,mapping.task),ResourceTransferId(ResourceTransferKind.Upload,mapping.upload),mapping.expectedBytes,mapping.authorization.expiresAt))
    fun bind(mapping:ResourceBackgroundDownloadMapping)=bind(NativeTransferProgressBinding(
        SystemTransferProgressKey(scope,ResourceTransferKind.Download,mapping.id,mapping.task),ResourceTransferId(ResourceTransferKind.Download,mapping.download),mapping.authorization.expectedBytes,mapping.authorization.expiresAt))
    internal fun bind(binding:NativeTransferProgressBinding)=synchronized(lock) {
        if(closed || binding.key.scope!=scope || binding.key.kind!=binding.transfer.kind || bindings.size>=64 && binding.key !in bindings) return
        bindings=bindings.put(binding.key,binding);bindingCount.value=bindings.size;refresh()
    }
    fun retire(mapping:String)=synchronized(lock) {
        bindings=bindings.filterKeys {it.mapping!=mapping}.toPersistentMap();bindingCount.value=bindings.size;refresh()
    }
    private fun refresh()=synchronized(lock) {
        if(!closed) hub.nativeProgress(snapshot(bindings.values,registry.samples.value,now()))
    }
    suspend fun observe():Unit=coroutineScope {
        launch {registry.samples.collect {refresh()}}
        // Expiry must remove an idle 100% observation even when no new bytes arrive.
        while(isActive) {bindingCount.first {it>0};delay(250);refresh()}
    }
    fun close()=synchronized(lock) {closed=true;bindings=persistentMapOf();bindingCount.value=0;hub.nativeProgress(persistentMapOf())}
    companion object {
        internal fun snapshot(bindings:Collection<NativeTransferProgressBinding>,samples:PersistentMap<SystemTransferProgressKey,ResourceTransferAttemptProgress>,now:Long):PersistentMap<ResourceTransferId,ResourceTransferAttemptProgress> {
            if(bindings.size>64 || samples.size>64) return persistentMapOf()
            val result=persistentMapOf<ResourceTransferId,ResourceTransferAttemptProgress>().builder();val seen=mutableSetOf<ResourceTransferId>()
            for(binding in bindings) {
                if(!seen.add(binding.transfer)) {result.remove(binding.transfer);continue}
                if(binding.transfer.kind==ResourceTransferKind.ServerImport || binding.key.kind!=binding.transfer.kind || binding.expectedBytes<=0 || binding.expiresAt<=now) continue
                val sample=samples[binding.key] ?: continue
                if(sample.attemptId==binding.key.mapping && sample.expectedBytes==binding.expectedBytes) result[binding.transfer]=sample
            }
            return result.build()
        }
    }
}
