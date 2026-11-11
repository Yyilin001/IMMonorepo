package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

data class SyncCursor(val generation: Long = 0, val sequence: Long = 0, val token: String = "", val pendingReceipt: String? = null,
    val pendingSequence: Long? = pendingReceipt?.let {sequence}) {
    init {require(generation>=0 && sequence>=0 && (pendingReceipt==null)==(pendingSequence==null));require(pendingSequence==null || pendingSequence in 0..sequence)}
}
/** Persisted reset authority, before its manifest or any snapshot pages have been requested. */
data class SyncReset(val snapshotId: String, val generation: Long, val baseSequence: Long, val expiresAtMillis: Long) {
    init { require(snapshotId.isNotBlank() && generation > 0 && baseSequence >= 0) }
}
enum class IncrementalSyncStopReason { CaughtUp, PageLimit, ResetPending }
data class IncrementalSyncResult(val processedPageCount: Int, val didCommitNewRecords: Boolean, val stopReason: IncrementalSyncStopReason)

/** The retained projection cannot prove an old batch; request a new authoritative baseline. */
class SyncReplayUnavailable: Exception("同步重放依据不足，需要重新取得快照")
data class SnapshotItem(val kind: String, val key: String, val sourceEvent: String, val sequence: Long, val payload: ByteString)
interface SyncStore {
    /** One account store owns the gate, including across replacement SyncEngine instances. */
    val syncMutex: Mutex
    suspend fun cursor(): SyncCursor
    /** Atomic projection + cursor + exact pending ACK receipt. Must reject an invalid projection before commit. */
    suspend fun commit(batch: SyncBatch, expected: SyncCursor)
    suspend fun acknowledged(expected: SyncCursor)
    suspend fun discardSyncCapabilities(expected: SyncCursor)
    suspend fun requestSnapshotRebuild()
    suspend fun requiresSnapshotRebuild(): Boolean
    /** Compare the exact pending manifest, then remove only shadow data and old capabilities. */
    suspend fun cancelSnapshot(expected: SnapshotManifest)
    suspend fun pendingReset(): SyncReset?
    /** Compare the observed cursor and atomically preserve the exact reset for a later foreground run. */
    suspend fun stageReset(expected: SyncCursor, reset: SyncReset)
    /** Explicit server rejection removes only this reset and its old continuation capabilities. */
    suspend fun cancelReset(expected: SyncReset)
    suspend fun pendingSnapshot(): SnapshotManifest?
    suspend fun stage(manifest: SnapshotManifest)
    suspend fun page(index: Int): SnapshotPage?
    suspend fun stage(page: SnapshotPage)
    suspend fun snapshotImportProgress(manifest: SnapshotManifest): SnapshotImportProgress
    /** Validate and atomically persist one page, decoded rows and the new prefix. */
    suspend fun importSnapshotPage(manifest: SnapshotManifest,page: SnapshotPage): SnapshotImportProgress
    suspend fun prepareSnapshotActivation(manifest: SnapshotManifest)
    suspend fun activateAcknowledgedSnapshot(manifest: SnapshotManifest)
    /** Atomically install the fully validated shadow projection; preserve local outbox. */
    suspend fun validateSnapshot(items: PersistentList<SnapshotItem>)
    suspend fun activate(manifest: SnapshotManifest, items: PersistentList<SnapshotItem>)
}

class SyncEngine(private val transport: EnvelopeTransport, private val store: SyncStore) {
    private val mutex get() = store.syncMutex
    suspend fun synchronize() { while(synchronizeTurn()) kotlinx.coroutines.yield() }
    /** Returns true while incremental or snapshot recovery remains; each turn imports at most the page budget. */
    suspend fun synchronizeTurn(maximumBatches: Int = 4, maximumSnapshotPages: Int = 4): Boolean = mutex.withLock {synchronizeTurnLocked(maximumBatches,maximumSnapshotPages)}
    /** The returned checkpoint was observed after a complete, acknowledged pull under this engine's lock. */
    suspend fun synchronizeForCompletion(maximumBatches: Int = 4, maximumSnapshotPages: Int = 4): SyncCursor? = mutex.withLock {
        if(synchronizeTurnLocked(maximumBatches,maximumSnapshotPages)) null else store.cursor()
    }
    /** Each cycle shares the store gate with foreground engines. Never fetches a manifest or snapshot page.
     * Time limits belong to the caller; an existing reset counts as one processed cycle, as in Swift. */
    suspend fun synchronizeIncrementally(maximumPages: Int): IncrementalSyncResult {
        require(maximumPages > 0)
        var committed = false
        for (page in 1..maximumPages) {
            coroutineContext.ensureActive()
            val cycle = mutex.withLock {
                coroutineContext.ensureActive()
                val before = store.cursor().sequence
                val more = synchronizeTurnLocked(1, 1, incrementalOnly = true)
                val reset = store.pendingReset() != null || store.pendingSnapshot() != null
                val changed = !reset && store.cursor().sequence > before
                Triple(more, reset, changed)
            }
            committed = committed || cycle.third
            if (cycle.second) return IncrementalSyncResult(page, committed, IncrementalSyncStopReason.ResetPending)
            if (!cycle.first) return IncrementalSyncResult(page, committed, IncrementalSyncStopReason.CaughtUp)
        }
        return IncrementalSyncResult(maximumPages, committed, IncrementalSyncStopReason.PageLimit)
    }
    private suspend fun synchronizeTurnLocked(maximumBatches: Int,maximumSnapshotPages: Int, incrementalOnly: Boolean = false): Boolean {
        require(maximumBatches > 0 && maximumSnapshotPages > 0)
        var batches = 0
        coroutineContext.ensureActive()
        store.pendingSnapshot()?.let { if (!incrementalOnly) recover(it,maximumSnapshotPages); return true }
        store.pendingReset()?.let { if (!incrementalOnly) recoverReset(it,maximumSnapshotPages); return true }
        var more: Boolean
        do {
            coroutineContext.ensureActive()
            acknowledgePending()
            var cursor = store.cursor()
            val rebuilding=store.requiresSnapshotRebuild()
            suspend fun pull()=transport.request(Envelope.newBuilder().setSyncPull(SyncPull.newBuilder()
                .setSyncToken(if(rebuilding) "" else cursor.token).setRequireSnapshot(rebuilding).setMaxRecords(200)))
            val result=try {pull()} catch(error: GatewayFailure) {
                if(error.code!="SYNC_TOKEN_INVALID" || error.retryable) throw error
                store.discardSyncCapabilities(cursor);cursor=store.cursor()
                pull() // At most one capability-free retry; a second rejection is propagated.
            }
            coroutineContext.ensureActive()
            more = false
            when {
                result.hasSyncBatch() -> {
                    if(rebuilding) throw ClientFailure.Protocol()
                    val batch = result.syncBatch
                    if (batch.recordsCount > 200 || (batch.hasMore && batch.recordsCount == 0) || batch.capabilityProfile != "base" || batch.nextSyncToken.isBlank() || batch.syncReceipt.isBlank() ||
                        batch.generation <= 0 || (cursor.generation != 0L && batch.generation != cursor.generation)) throw ClientFailure.Protocol()
                    var previous: Long? = null
                    var applied=cursor.sequence
                    for (record in batch.recordsList) {
                        val sequence=record.userSyncSequence
                        if (sequence<=0 || previous?.let {it==Long.MAX_VALUE || sequence!=it+1}==true ||
                            sequence>applied && (applied==Long.MAX_VALUE || sequence!=applied+1) ||
                            record.sourceEventId.isBlank() || record.projectionKind.isBlank() || record.projectionKind in setOf("message", "message_reaction", "moderation", "group_capability") || record.payload.isEmpty)
                            throw ClientFailure.Protocol()
                        previous=sequence;applied=maxOf(applied,sequence)
                    }
                    try {
                        store.commit(batch, cursor)
                        val acknowledged=acknowledgePending()
                        more = batch.hasMore || !acknowledged
                    } catch(error: SyncReplayUnavailable) {
                        store.requestSnapshotRebuild();more=true
                    }
                }
                result.hasResetRequired() -> {
                    val value = result.resetRequired
                    if (value.snapshotId.isBlank() || value.generation <= 0 || value.baseUserSyncSequence < 0) throw ClientFailure.Protocol()
                    val reset = SyncReset(value.snapshotId, value.generation, value.baseUserSyncSequence, value.expiresAtMs)
                    store.stageReset(cursor, reset)
                    if (!incrementalOnly) recoverReset(reset, maximumSnapshotPages)
                    return true // Snapshot work consumes this turn; observe the new cursor next turn.
                }
                else -> throw ClientFailure.Protocol()
            }
            batches++
        } while (more && batches < maximumBatches)
        return more
    }
    private suspend fun recoverReset(reset: SyncReset, maximumSnapshotPages: Int) {
        coroutineContext.ensureActive()
        val response = try { transport.request(Envelope.newBuilder().setSyncSnapshot(SyncSnapshot.newBuilder()
            .setSnapshotId(reset.snapshotId).setGeneration(reset.generation))) } catch (error: GatewayFailure) {
            if (error.code == "RESET_REQUIRED" && !error.retryable) store.cancelReset(reset)
            throw error
        }
        coroutineContext.ensureActive()
        if (!response.hasSnapshotManifest() || response.snapshotManifest.snapshotId != reset.snapshotId ||
            response.snapshotManifest.generation != reset.generation || response.snapshotManifest.baseUserSyncSequence != reset.baseSequence)
            throw ClientFailure.Protocol()
        SnapshotImportValidation.validateManifest(response.snapshotManifest)
        // Store adoption atomically replaces the pending reset with this exact matching manifest.
        store.stage(response.snapshotManifest)
        recover(response.snapshotManifest, maximumSnapshotPages)
    }
    private suspend fun acknowledgePending(): Boolean {
        val cursor = store.cursor()
        val receipt = cursor.pendingReceipt ?: return true
        val result = try {transport.request(Envelope.newBuilder().setSyncAck(SyncAck.newBuilder().setGeneration(cursor.generation)
            .setHighestContiguousSequence(requireNotNull(cursor.pendingSequence)).setSyncReceipt(receipt)))} catch(error: GatewayFailure) {
                if(error.code!="SYNC_RECEIPT_INVALID" || error.retryable) throw error
                store.discardSyncCapabilities(cursor);return false
            }
        coroutineContext.ensureActive()
        if (!result.hasAcknowledged()) throw ClientFailure.Protocol()
        store.acknowledged(cursor)
        return true
    }
    private suspend fun recover(manifest: SnapshotManifest,maximumPages:Int) {
        SnapshotImportValidation.validateManifest(manifest)
        var progress=store.snapshotImportProgress(manifest)
        var processed=0
        while(processed<maximumPages && progress.nextPage<manifest.pageCount) {
            coroutineContext.ensureActive()
            val page=store.page(progress.nextPage) ?: snapshotRequest(manifest,Envelope.newBuilder().setSnapshotPagePull(SnapshotPagePull.newBuilder()
                .setSnapshotId(manifest.snapshotId).setGeneration(manifest.generation).setRootDigest(manifest.rootDigest).setPageIndex(progress.nextPage)))
                .let {if(!it.hasSnapshotPage()) throw ClientFailure.Protocol();it.snapshotPage}
            coroutineContext.ensureActive()
            progress=store.importSnapshotPage(manifest,page);processed++
        }
        if(progress.nextPage<manifest.pageCount) return
        SnapshotImportValidation.validateComplete(manifest,progress)
        store.prepareSnapshotActivation(manifest)
        val ack=snapshotRequest(manifest,Envelope.newBuilder().setSnapshotAck(SnapshotAck.newBuilder().setSnapshotId(manifest.snapshotId)
            .setGeneration(manifest.generation).setBaseUserSyncSequence(manifest.baseUserSyncSequence).setSnapshotReceipt(manifest.syncReceipt)))
        coroutineContext.ensureActive()
        if(!ack.hasAcknowledged()) throw ClientFailure.Protocol()
        store.activateAcknowledgedSnapshot(manifest)
    }
    private suspend fun snapshotRequest(manifest: SnapshotManifest,request: Envelope.Builder): Envelope = try {transport.request(request)} catch(error: GatewayFailure) {
        if(error.code=="RESET_REQUIRED" && !error.retryable) store.cancelSnapshot(manifest)
        throw error
    }
}
internal fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
