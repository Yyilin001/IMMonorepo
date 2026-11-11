package com.xmtx.im.client

import kotlinx.coroutines.CompletableDeferred

/** Account-wide encoded display budget, including physically running downloads. FIFO admission. */
class GroupAvatarDisplayBudget(val maximumBytes: Long=8L*1024*1024) {
    private data class Waiting(val bytes: Long,val ready: CompletableDeferred<Unit>)
    private val lock=Any()
    private val held=mutableMapOf<Any,Long>()
    private val waiting=linkedMapOf<Any,Waiting>()
    private var bytes=0L
    init { require(maximumBytes in 1..64L*1024*1024) }
    suspend fun acquire(owner: Any,count: Long) {
        require(count in 1..maximumBytes)
        val ready=synchronized(lock) {
            check(owner !in held && owner !in waiting)
            CompletableDeferred<Unit>().also { signal ->
                if(waiting.isEmpty() && count<=maximumBytes-bytes) { held[owner]=count;bytes+=count;signal.complete(Unit) }
                else waiting[owner]=Waiting(count,signal)
            }
        }
        try { ready.await() } catch(error: Throwable) { release(owner);throw error }
    }
    fun release(owner: Any) {
        val ready=synchronized(lock) {
            waiting.remove(owner)?.ready?.cancel();held.remove(owner)?.let { bytes-=it }
            buildList {
                while(waiting.isNotEmpty()) {
                    val entry=waiting.entries.first()
                    if(entry.value.bytes>maximumBytes-bytes) break
                    waiting.remove(entry.key);held[entry.key]=entry.value.bytes;bytes+=entry.value.bytes;add(entry.value.ready)
                }
            }
        }
        ready.forEach { it.complete(Unit) }
    }
    data class Diagnostics(val bytes: Long,val owners: Int,val waiting: Int)
    fun diagnostics()=synchronized(lock) { Diagnostics(bytes,held.size,waiting.size) }
}
