package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

data class DeviceRevocationPrompt(val command: DeviceRevocationCommand, val deadlineNanos: Long)
data class DeviceManagementState(val sessions: PersistentList<DeviceSession> = persistentListOf(), val cursor: String? = null,
    val baseline: DeviceRevocationBaseline? = null, val works: PersistentList<DeviceRevocationWork> = persistentListOf(),
    val prompt: DeviceRevocationPrompt? = null, val loading: Boolean = false, val loadingMore: Boolean = false, val error: String? = null)
/** Page activation; stale reads can never restore management authority after a mutation or close. */
class DeviceManagement(private val client: DeviceSessionClient, private val operations: DeviceRevocationService,
    private val now: () -> Long = System::currentTimeMillis, private val monotonic: () -> Long = System::nanoTime) {
    private val mutableState = MutableStateFlow(DeviceManagementState())
    val state = mutableState.asStateFlow()
    private val lock = Any()
    private var generation = 0L
    private var closed = false
    private var baselineEnd = 0L
    private var loadedWorks = false
    private val seenCursors = mutableSetOf<String>()
    fun close() = synchronized(lock) { closed = true; generation++; operations.close(); mutableState.value = DeviceManagementState() }
    fun dismiss() = synchronized(lock) { mutableState.update { it.copy(prompt = null) } }
    suspend fun refresh() {
        val version = synchronized(lock) {
            if(closed) return
            generation++; seenCursors.clear(); baselineEnd = 0
            mutableState.update { it.copy(baseline = null, prompt = null, loading = true, loadingMore = false, error = null, cursor = null) }; generation
        }
        try {
            val page = client.list()
            synchronized(lock) {
                if(closed || version != generation) return
                mutableState.update { it.copy(sessions = visible(page.sessions, it.works), cursor = page.cursor) }
            }
            val baseline = operations.baseline()
            synchronized(lock) {
                if(closed || version != generation) return
                baselineEnd = monotonic() + (baseline.expiresAt - now()).coerceIn(0,120000) * 1000000
                mutableState.update { it.copy(baseline = baseline, loading = false) }
            }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { failed(e, version) }
    }
    suspend fun more() {
        val request = synchronized(lock) {
            val value = state.value
            if(closed || value.loading || value.loadingMore || value.cursor == null) return
            if(!seenCursors.add(value.cursor)) { mutableState.update { it.copy(cursor = null, error = "分页游标重复，请刷新") }; return }
            mutableState.update { it.copy(loadingMore = true, error = null) }; generation to value.cursor
        }
        try {
            val page = client.list(request.second)
            synchronized(lock) {
                if(closed || generation != request.first) return
                mutableState.update { current -> current.copy(sessions = visible((current.sessions + page.sessions).distinctBy { it.device }.toPersistentList(), current.works), cursor = page.cursor, loadingMore = false) }
            }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { synchronized(lock) { if(generation == request.first) seenCursors.remove(request.second) }; failed(e, request.first) }
    }
    fun propose(selection: DeviceId?) = synchronized(lock) {
        check(!closed)
        val value = state.value; val baseline = requireNotNull(value.baseline)
        require(!value.loading && monotonic() < baselineEnd && now() < baseline.expiresAt)
        val command = DeviceRevocationCommand(UUID.randomUUID().toString().uppercase(), baseline, selection, baseline.expiresAt)
        require(command.targets.isNotEmpty() && value.works.none { it.receipt == null && it.command.targets.any(command.targets::contains) })
        mutableState.update { it.copy(prompt = DeviceRevocationPrompt(command, minOf(baselineEnd, monotonic() + 30000000000)), error = null) }
    }
    suspend fun confirm() {
        val command = synchronized(lock) {
            if(closed) return
            val prompt = state.value.prompt ?: return
            mutableState.update { it.copy(prompt = null) }
            require(monotonic() < prompt.deadlineNanos && now() < prompt.command.deadline)
            generation++; mutableState.update { it.copy(baseline = null, loading = false, loadingMore = false) }; prompt.command
        }
        try { operations.enqueue(command); readWorks() }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) { failed(e, synchronized(lock) { generation }) }
    }
    suspend fun resume(operation: String) { operations.resume(operation); readWorks() }
    suspend fun tick() {
        try { readWorks(); operations.flush(); readWorks() }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) { failed(e, synchronized(lock) { generation }) }
    }
    private suspend fun readWorks() {
        val records = operations.works()
        synchronized(lock) {
            if(closed) return
            val previous = state.value
            val newReceipt = loadedWorks && records.any { it.receipt != null && previous.works.none { old -> old.command.operation == it.command.operation && old.receipt != null } }
            loadedWorks = true
            if(newReceipt) generation++
            mutableState.value = previous.copy(works = records, sessions = visible(previous.sessions, records),
                baseline = if(newReceipt) null else previous.baseline, prompt = if(newReceipt) null else previous.prompt,
                loading = if(newReceipt) false else previous.loading, loadingMore = if(newReceipt) false else previous.loadingMore)
        }
    }
    private fun failed(error: Exception, version: Long) = synchronized(lock) {
        if(closed || version != generation) return@synchronized
        val unauthorized = error is ClientFailure.SignedOut || error is ClientFailure.Http && error.status in setOf(401,403)
        mutableState.update { it.copy(sessions = if(unauthorized) persistentListOf() else it.sessions, baseline = null, prompt = null,
            loading = false, loadingMore = false, error = if(unauthorized) "登录或管理权限已失效，请重新登录" else "设备状态未确认，请刷新或继续确认原操作") }
    }
    private fun visible(sessions: PersistentList<DeviceSession>, works: PersistentList<DeviceRevocationWork>) = sessions.filter { session ->
        works.none { it.receipt?.outcome == DeviceRevocationOutcome.Revoked && session.device in it.command.targets && session.createdAt <= it.receipt.resolvedAt }
    }.toPersistentList()
}
