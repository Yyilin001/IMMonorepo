package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow

/** Visible text only, independent of HTTP/lease renewal. Owner calls update/close on its UI dispatcher. */
internal class LocalProfilePage(private val actor: UserId, private val owner: CoroutineScope,
    private val reader: LocalProfileDisplayReading,
    private val fences: suspend (PersistentList<ProfileKey>) -> ProfileFenceSnapshot,
    changes: Flow<Long>, private val publish: (PersistentMap<ProfileKey, LocalProfileDisplaySnapshot.Value>) -> Unit) {
    private var keys = persistentListOf<ProfileKey>()
    private var generation = ""
    private var revision = 0L
    private var closed = false
    private var read: Job? = null
    private val observation = owner.launch { changes.collect { reload() } }
    fun update(keys: PersistentList<ProfileKey>, generation: String) {
        require(keys.size <= 128 && keys.distinct().size == keys.size)
        this.keys = keys; this.generation = generation; reload()
    }
    private fun reload() {
        if (closed) return
        val captured = ++revision; val requested = keys; val expectedGeneration = generation
        read?.cancel(); publish(persistentMapOf())
        if (requested.isEmpty()) return
        read = owner.launch {
            try {
                val before = fences(requested)
                if (before.generation != expectedGeneration) return@launch
                val local = reader.load(requested, before) ?: return@launch
                val after = fences(requested)
                ensureActive()
                if (closed || revision != captured || before != after) return@launch
                val values = requested.mapNotNull { key ->
                    val basic = local.basics[key.user] ?: return@mapNotNull null
                    require(basic.alias == null || basic.alias.owner == actor)
                    local.records[key]?.alias?.let { require(it.owner == actor) }
                    // Ordinary content floors keep old local text; security floors explicitly hide it.
                    if (basic.profileRevision <= (after.floors[key]?.securityRevision ?: Long.MAX_VALUE)) null
                    else local.value(key)?.let { key to it }
                }.toMap().toPersistentMap()
                publish(values)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { /* Fail closed until the next change or page activation. */ }
        }
    }
    fun close() {
        if (closed) return
        closed = true; revision++; read?.cancel(); observation.cancel(); keys = persistentListOf(); publish(persistentMapOf())
    }
}
