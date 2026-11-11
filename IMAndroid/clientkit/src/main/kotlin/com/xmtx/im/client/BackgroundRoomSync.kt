package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference

class BackgroundRoomCoverageLost : IOException("Background room coverage lost")

/** Bounded room recovery on an already authenticated, dedicated background connection.
 * Use run as BackgroundSyncRunner's roomSync callback. The runtime must drain its foreground
 * directory driver before handing over the store: beginDirectory replaces its connection scope.
 * This adapter never claims live coverage or performs a final personal catch-up.
 */
class BackgroundRoomSync internal constructor(
    private val transport: EnvelopeTransport,
    private val state: StateFlow<RealtimeConnectionState>,
    private val events: Flow<RealtimeSyncEvent>,
    private val retireConnection: () -> Unit,
    private val store: RoomDirectoryStore,
    roomStore: RoomStore,
    private val heads: AccountRoomHeadStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    constructor(connection: RealtimeConnection, directoryStore: RoomDirectoryStore,
        roomStore: RoomStore, heads: AccountRoomHeadStore) : this(connection, connection.state,
        connection.syncEvents, connection::close, directoryStore, roomStore, heads)

    init { require(store is RoomLatestVisibleStore) { "RoomLatestVisibleStore required for durable head recovery" } }
    private val running = Mutex()
    private val rooms = RoomSyncEngine(transport, roomStore)
    private val directory = RoomDirectoryRecovery(transport, store, rooms, now)
    private var headScan: RoomId? = null

    suspend fun run(maximumPages: Int): IncrementalSyncResult {
        require(maximumPages in 1..10_000)
        currentCoroutineContext().ensureActive()
        check(running.tryLock()) { "Background room recovery is already running" }
        try { return coroutineScope {
            val connection = state.value
            if (!connection.connected || connection.epoch <= 0) throw RealtimeUnavailableBeforeAdmission()
            val ready = AtomicReference<String?>(null)
            val consumer = launch(start = CoroutineStart.UNDISPATCHED) {
                events.collect { event ->
                    if (event.connectionEpoch != connection.epoch) return@collect
                    val hint = event.hint
                    if (hint is RealtimeSyncHint.AccountResync) {
                        // The receiver may deliver RESYNC directly after READY, before start resumes.
                        // Do not wait for that caller to publish the epoch: retire I/O immediately.
                        val expected = ready.get()
                        retireConnection()
                        if (expected != null && hint.recoveryEpoch != expected) throw ClientFailure.Protocol()
                        throw BackgroundRoomCoverageLost()
                    }
                    if (hint is RealtimeSyncHint.Coverage && hint.scope == SyncCoverageScope.Directory &&
                        (hint.state == ActivityCoverageState.Ended || hint.reason in setOf(SyncCoverageReason.Lost, SyncCoverageReason.Unavailable))) {
                        retireConnection(); throw BackgroundRoomCoverageLost()
                    }
                }
                retireConnection(); throw BackgroundRoomCoverageLost()
            }
            val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                state.collect {
                    if (!it.connected || it.epoch != connection.epoch) {
                        retireConnection(); throw BackgroundRoomCoverageLost()
                    }
                }
            }
            try {
                ready.set(AccountRoomChangesClient(transport).start())
                currentCoroutineContext().ensureActive()
                directory.start()
                // Personal heads are durable but are not membership grants. Queue summary/state
                // authorization before any body read, including when the saved directory is complete.
                val pending = heads.pendingRoomHeads(headScan, minOf(16, maximumPages))
                currentCoroutineContext().ensureActive()
                directory.ensureVisible(pending.map { it.room }.toPersistentList())
                pending.lastOrNull()?.let { headScan = it.room }
                var remaining = maximumPages
                var processed = 0
                var inserted = false
                while (remaining > 0) {
                    currentCoroutineContext().ensureActive()
                    val progress = directory.progress()
                    val directoryPages = if (!progress.complete && (remaining > 1 || progress.pendingRooms == 0)) 1 else 0
                    val result = directory.runBudget(directoryPages, minOf(16, remaining - directoryPages), roomPageLimit = 1)
                    val spent = result.directoryPages + result.processedRooms
                    processed += spent; remaining -= spent
                    inserted = inserted || result.appliedEventCount > 0
                    if (spent == 0) break
                }
                currentCoroutineContext().ensureActive()
                IncrementalSyncResult(processed, inserted, IncrementalSyncStopReason.PageLimit)
            } finally {
                consumer.cancel(); watcher.cancel()
                withContext(NonCancellable) { consumer.join(); watcher.join() }
            }
        } } finally { running.unlock() }
    }
}
