package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.RealtimeCoverage
import kotlinx.collections.immutable.*
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

enum class RealtimeCoverageScope { Account, Room, Directory, Presence, Typing }
/** Installation evidence for one physical connection, never authentication or read authority. */
data class RealtimeCoverageState(
    val connectionGeneration: Long, val scope: RealtimeCoverageScope, val scopeId: String,
    val scopeGeneration: Long, val highWatermark: Long, val connectionEpoch: String,
    val revision: Long, val status: ActivityCoverageState, val reason: SyncCoverageReason,
) {
    init {
        require(connectionGeneration > 0 && revision > 0 && scopeGeneration > 0 && highWatermark >= 0)
        require(UUID.fromString(scopeId).toString().equals(scopeId, true))
        require((status == ActivityCoverageState.Ready) == (reason == SyncCoverageReason.Confirmed))
        require(status != ActivityCoverageState.Ended || reason == SyncCoverageReason.Cancelled)
        require(status != ActivityCoverageState.Recovering || reason in setOf(SyncCoverageReason.Installing, SyncCoverageReason.Lost, SyncCoverageReason.Unavailable))
        if (scope == RealtimeCoverageScope.Directory && status == ActivityCoverageState.Ready)
            require(UUID.fromString(connectionEpoch).toString().equals(connectionEpoch, true))
    }
    val subscriptionInstalled: Boolean get() = status == ActivityCoverageState.Ready
    val baselineHead: Long? get() = highWatermark.takeIf { subscriptionInstalled }
    fun isCaughtUp(appliedThrough: Long): Boolean {
        require(appliedThrough >= 0)
        return subscriptionInstalled && appliedThrough >= highWatermark
    }
    companion object {
        internal fun decode(wire: RealtimeCoverage, generation: Long): RealtimeCoverageState = try {
            RealtimeCoverageState(generation, when (wire.scope) {
                RealtimeCoverage.Scope.ACCOUNT -> RealtimeCoverageScope.Account
                RealtimeCoverage.Scope.ROOM -> RealtimeCoverageScope.Room
                RealtimeCoverage.Scope.DIRECTORY -> RealtimeCoverageScope.Directory
                RealtimeCoverage.Scope.PRESENCE -> RealtimeCoverageScope.Presence
                RealtimeCoverage.Scope.TYPING -> RealtimeCoverageScope.Typing
                else -> throw ClientFailure.Protocol()
            }, canonicalId(wire.scopeId), wire.scopeGeneration, wire.highWatermark, wire.connectionEpoch,
                wire.revision, when (wire.state) {
                    RealtimeCoverage.State.RECOVERING -> ActivityCoverageState.Recovering
                    RealtimeCoverage.State.READY -> ActivityCoverageState.Ready
                    RealtimeCoverage.State.ENDED -> ActivityCoverageState.Ended
                    else -> throw ClientFailure.Protocol()
                }, when (wire.reason) {
                    RealtimeCoverage.Reason.REASON_UNSPECIFIED -> SyncCoverageReason.Confirmed
                    RealtimeCoverage.Reason.INSTALLING -> SyncCoverageReason.Installing
                    RealtimeCoverage.Reason.COVERAGE_LOST -> SyncCoverageReason.Lost
                    RealtimeCoverage.Reason.DEPENDENCY_UNAVAILABLE -> SyncCoverageReason.Unavailable
                    RealtimeCoverage.Reason.CANCELLED -> SyncCoverageReason.Cancelled
                    else -> throw ClientFailure.Protocol()
                })
        } catch (_: IllegalArgumentException) { throw ClientFailure.Protocol() }
    }
}
/** Full replacement; at most one active entry of each scope. Missing entries withdraw old coverage. */
data class RealtimeCoverageSnapshot(val connectionGeneration: Long? = null,
    val scopes: PersistentMap<RealtimeCoverageScope, RealtimeCoverageState> = persistentMapOf()) {
    init {
        require(connectionGeneration == null && scopes.isEmpty() || connectionGeneration != null && connectionGeneration > 0)
        require(scopes.all { (key, value) -> key == value.scope && value.connectionGeneration == connectionGeneration && value.status != ActivityCoverageState.Ended })
    }
}
interface RealtimeCoverageSource { val realtimeCoverage: StateFlow<RealtimeCoverageSnapshot> }

/** Called under the connection lock. Fences remain bounded even when a scope ends. */
internal class RealtimeCoverageTracker(private val epoch: Long) {
    private val revisions = mutableMapOf<RealtimeCoverageScope, Long>()
    private val generations = mutableMapOf<RealtimeCoverageScope, Long>()
    private val ended = mutableMapOf<RealtimeCoverageScope, Long>()
    private var states = persistentMapOf<RealtimeCoverageScope, RealtimeCoverageState>()
    fun accept(value: RealtimeCoverageState): Boolean {
        require(value.connectionGeneration == epoch)
        val kind = value.scope
        if (value.revision <= (revisions[kind] ?: 0) || value.scopeGeneration < (generations[kind] ?: 0) ||
            value.status != ActivityCoverageState.Ended && value.scopeGeneration <= (ended[kind] ?: 0)) return false
        val old = states[kind]
        if (old != null && old.scopeId == value.scopeId && old.subscriptionInstalled && value.subscriptionInstalled &&
            old.scopeGeneration == value.scopeGeneration && old.connectionEpoch == value.connectionEpoch && old.baselineHead != value.baselineHead)
            throw ClientFailure.Protocol()
        revisions[kind] = value.revision; generations[kind] = value.scopeGeneration
        if (value.status == ActivityCoverageState.Ended) { ended[kind] = value.scopeGeneration; states = states.remove(kind) }
        else states = states.put(kind, value)
        return true
    }
    fun snapshot() = RealtimeCoverageSnapshot(epoch, states)
    fun room(epoch: Long): RoomProgressScope? = states[RealtimeCoverageScope.Room]?.takeIf { it.subscriptionInstalled && it.connectionGeneration == epoch }
        ?.let { RoomProgressScope(epoch, RoomId(it.scopeId), it.scopeGeneration, it.highWatermark) }
    fun clear() { revisions.clear(); generations.clear(); ended.clear(); states = persistentMapOf() }
}
